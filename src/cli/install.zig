//! `nayr install` Command
//!
//! The main install pipeline: resolve → fetch → link → scripts → integrity.
//! Supports all Yarn Classic install flags.

const std = @import("std");
const resolver_mod = @import("../core/resolver.zig");
const fetcher_mod = @import("../core/fetcher.zig");
const linker_mod = @import("../core/linker.zig");
const scripts_mod = @import("../core/scripts.zig");
const integrity_mod = @import("../core/integrity.zig");
const hoister_mod = @import("../core/hoister.zig");
const cache_mod = @import("../core/cache.zig");
const nayr_fmt = @import("../lockfile/nayr_format.zig");
const ws_discovery = @import("../workspace/discovery.zig");
const nohoist_mod = @import("../workspace/nohoist.zig");
const json_util = @import("../util/json.zig");
const platform = @import("../util/platform.zig");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const link_cmd = @import("link.zig");
const Config = config_types.Config;

// ============================================================================
// Install options
// ============================================================================

/// All flags supported by `nayr install`.
pub const InstallOptions = struct {
    frozen_lockfile: bool = false,
    production: bool = false,
    include_optional: bool = true,
    ignore_optional: bool = false,
    ignore_platform: bool = false,
    ignore_engines: bool = false,
    force: bool = false,
    flat: bool = false,
    check_files: bool = false,
    ignore_scripts: bool = false,
    concurrency: u32 = 32,
};

// ============================================================================
// Command entry point
// ============================================================================

/// Runs `nayr install`.
///
/// ## Parameters
/// - `allocator`: Main allocator.
/// - `args`: Arguments after "install".
/// - `cwd`: Project root directory.
/// - `config`: Merged configuration.
/// - `writer`: Output event sink.
pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    const opts = parseInstallOpts(args, config);
    const start = std.time.milliTimestamp();

    // Validate that a package.json exists in the target directory before
    // doing any work. This produces a clear message instead of a cryptic
    // FileNotFound later in the pipeline.
    const pkg_json_path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(pkg_json_path);
    std.fs.accessAbsolute(pkg_json_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const stderr = std.io.getStdErr().writer();
            const colour = output.hasTtyStderr();
            stderr.print(
                "{s}error{s} No package.json found in {s}\n" ++
                    "      Make sure you are inside a Node.js project directory.\n",
                .{
                    if (colour) "\x1b[1;31m" else "",
                    if (colour) "\x1b[0m" else "",
                    cwd,
                },
            ) catch {};
            std.process.exit(1);
        },
        else => return err,
    };

    // Auto-register this package as a global link if its name matches one of
    // the glob patterns declared in `.nayrrc [links]`.
    if (config.auto_link_patterns.len > 0) {
        if (json_util.parseFile(allocator, pkg_json_path)) |manifest_val| {
            var manifest = manifest_val;
            defer manifest.deinit(allocator);
            if (manifest.name) |name| {
                if (matchesAutoLinkPattern(name, config.auto_link_patterns)) {
                    link_cmd.registerPackage(allocator, name, cwd, writer) catch {};
                }
            }
        } else |_| {}
    }

    // Pre-install relink: apply any registered links for deps in this project.
    //
    // This runs before the integrity fast-path so that a link registered by a
    // sibling package's recent install is picked up immediately - even when
    // nothing else in node_modules has changed.  Also fixes the case where a
    // git-dep clone previously failed and left an empty directory: the correct
    // symlink replaces it here without requiring a full reinstall.
    link_cmd.applyRegisteredLinks(allocator, cwd, writer) catch {};

    // Repair bin stubs: walk node_modules/ and create any missing .bin/ stubs.
    //
    // This lightweight pass runs before the integrity fast-path so that bin
    // stubs are always present even when a previous install was interrupted, the
    // integrity file was written before stubs were created, or .bin/ was cleaned
    // manually. The pass is idempotent and skips packages that already have all
    // their stubs in place.
    linker_mod.repairBinStubs(allocator, cwd, writer) catch {};

    // Repair broken packages: walk node_modules/ and remove any package
    // directory that has no package.json (empty stub from a failed extraction).
    // Removing it causes the integrity hash to miss the package → full reinstall.
    linker_mod.repairBrokenPackages(allocator, cwd, writer) catch {};

    // Fast path: integrity check.
    if (!opts.force and !opts.check_files) {
        if (try integrity_mod.isUpToDate(allocator, cwd)) {
            writer.emit(.{ .done = .{
                .elapsed_ms = @intCast(std.time.milliTimestamp() - start),
                .summary = "Already up to date.",
            } });
            return;
        }
    }

    // --- Phase 0: Root preinstall ---
    if (!opts.ignore_scripts and !config.ignore_scripts) {
        try scripts_mod.runRootPre(allocator, cwd, writer);
    }

    // --- Phase 1: Resolve ---
    const res_opts = resolver_mod.ResolverOptions{
        .frozen_lockfile = opts.frozen_lockfile,
        .production = opts.production,
        .ignore_optional = opts.ignore_optional,
        .force = opts.force,
        .concurrency = opts.concurrency,
    };
    var resolution = try resolver_mod.resolve(allocator, cwd, config, res_opts, writer);
    defer resolution.deinit();

    // Print resolved summary (also clears the spinner line).
    {
        const n = resolution.packages.count();
        const msg = try std.fmt.allocPrint(allocator, "Resolved {d} package{s}", .{
            n, if (n == 1) "" else "s",
        });
        defer allocator.free(msg);
        writer.emit(.{ .info = msg });
    }

    // --- Phase 2: Fetch ---
    const cache_dir = try platform.getCacheDir(allocator);
    defer allocator.free(cache_dir);
    var cache = try cache_mod.Cache.init(allocator, cache_dir);
    defer cache.deinit();

    writer.emit(.{ .info = "Fetching packages..." });
    try fetcher_mod.fetchAll(
        allocator,
        &resolution.packages,
        &cache,
        config,
        writer,
        .{ .concurrency = opts.concurrency },
    );

    // --- Phase 3: Hoist ---
    const workspaces = try ws_discovery.discover(allocator, cwd);
    defer {
        for (workspaces) |*ws| {
            allocator.free(ws.path);
            allocator.free(ws.rel_path);
            var m = ws.manifest;
            m.deinit(allocator);
        }
        allocator.free(workspaces);
    }
    const root_manifest_path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(root_manifest_path);
    var root_manifest = try json_util.parseFile(allocator, root_manifest_path);
    defer root_manifest.deinit(allocator);
    const nohoist_patterns = ws_discovery.nohoistPatterns(&root_manifest);
    const checker = nohoist_mod.NohoistChecker.init(nohoist_patterns);

    // Build the root direct-dep ranges map (name → range) for the hoister so
    // that root-pinned packages always win their root node_modules slot over
    // more-popular transitive packages that require a different version.
    var root_dep_ranges = std.StringHashMapUnmanaged([]const u8){};
    defer root_dep_ranges.deinit(allocator);
    {
        var di = root_manifest.dependencies.iterator();
        while (di.next()) |kv| try root_dep_ranges.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
        var ddi = root_manifest.dev_dependencies.iterator();
        while (ddi.next()) |kv| try root_dep_ranges.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
        var odi = root_manifest.optional_dependencies.iterator();
        while (odi.next()) |kv| try root_dep_ranges.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
        // Include workspace package deps so that workspace-level pins also win.
        for (workspaces) |*ws| {
            var wdi = ws.manifest.dependencies.iterator();
            while (wdi.next()) |kv| _ = try root_dep_ranges.getOrPutValue(allocator, kv.key_ptr.*, kv.value_ptr.*);
            var wddi = ws.manifest.dev_dependencies.iterator();
            while (wddi.next()) |kv| _ = try root_dep_ranges.getOrPutValue(allocator, kv.key_ptr.*, kv.value_ptr.*);
        }
    }

    const hoisted = try hoister_mod.hoist(allocator, &resolution.packages, &checker, &root_dep_ranges);
    defer {
        for (hoisted) |hp| allocator.free(hp.install_path);
        allocator.free(hoisted);
    }

    // Build workspace name → path map for the linker.
    // Also includes packages resolved from the link registry (is_linked = true),
    // where tarball_url holds the absolute path to the dev checkout.
    var ws_paths = std.StringHashMapUnmanaged([]const u8){};
    defer ws_paths.deinit(allocator);
    for (workspaces) |*ws| {
        const name = ws.manifest.name orelse continue;
        // Skip workspace entries whose path is inside node_modules/ - these are
        // a Yarn Classic quirk (e.g. workspaces: ["node_modules/@scope/pkg"]) that
        // nayr resolves through the link registry instead.  Using the node_modules
        // path directly would create a self-referential symlink.
        if (std.mem.indexOf(u8, ws.rel_path, "node_modules") != null) continue;
        try ws_paths.put(allocator, name, ws.path);
    }
    {
        var pkg_it = resolution.packages.valueIterator();
        while (pkg_it.next()) |pkg| {
            if (pkg.is_linked and pkg.tarball_url.len > 0) {
                // Link-registry packages override workspace-discovery paths so
                // that a local dev checkout always wins over a node_modules entry.
                try ws_paths.put(allocator, pkg.name, pkg.tarball_url);
            }
        }
    }

    // --- Phase 4: Link ---
    writer.emit(.{ .info = "Linking packages..." });
    try linker_mod.link(allocator, cwd, hoisted, &cache, &ws_paths, writer);

    // --- Phase 5: Scripts ---
    if (!opts.ignore_scripts and !config.ignore_scripts) {
        writer.emit(.{ .info = "Running lifecycle scripts..." });
        try scripts_mod.runAll(allocator, cwd, hoisted, writer);
        try scripts_mod.runRootPost(allocator, cwd, writer);
    }

    // --- Phase 6: Write lockfile ---
    const lockfile_path = try std.fs.path.join(allocator, &.{ cwd, "nayr.lock" });
    defer allocator.free(lockfile_path);
    try nayr_fmt.writeFile(&resolution.lockfile, lockfile_path, allocator);

    // --- Phase 7: Save integrity ---
    try integrity_mod.save(allocator, cwd);

    const elapsed: u64 = @intCast(std.time.milliTimestamp() - start);
    const summary = try std.fmt.allocPrint(
        allocator,
        "{d} packages installed",
        .{resolution.packages.count()},
    );
    defer allocator.free(summary);
    writer.emit(.{ .done = .{ .elapsed_ms = elapsed, .summary = summary } });
}

// ============================================================================
// Helpers
// ============================================================================

/// Returns true when `pkg_name` matches any of the auto-link glob patterns.
///
/// Supported pattern forms:
///   `@scope/*`  - matches any package under that scope
///   `@scope/x`  - exact match (degenerate case, same as a literal name)
fn matchesAutoLinkPattern(pkg_name: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pat| {
        // Wildcard: "@scope/*" matches any "@scope/<anything>"
        if (std.mem.endsWith(u8, pat, "/*")) {
            const prefix = pat[0 .. pat.len - 1]; // "@scope/"
            if (std.mem.startsWith(u8, pkg_name, prefix)) return true;
        } else {
            // Exact match.
            if (std.mem.eql(u8, pkg_name, pat)) return true;
        }
    }
    return false;
}

// ============================================================================
// Option parser
// ============================================================================

fn parseInstallOpts(args: []const []const u8, config: *const Config) InstallOptions {
    var opts = InstallOptions{
        .ignore_scripts = config.ignore_scripts,
        .ignore_optional = config.ignore_optional,
    };

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--frozen-lockfile")) opts.frozen_lockfile = true;
        if (std.mem.eql(u8, arg, "--production") or std.mem.eql(u8, arg, "--prod")) opts.production = true;
        if (std.mem.eql(u8, arg, "--include-optional")) opts.include_optional = true;
        if (std.mem.eql(u8, arg, "--ignore-optional")) opts.ignore_optional = true;
        if (std.mem.eql(u8, arg, "--ignore-platform")) opts.ignore_platform = true;
        if (std.mem.eql(u8, arg, "--ignore-engines")) opts.ignore_engines = true;
        if (std.mem.eql(u8, arg, "--force")) opts.force = true;
        if (std.mem.eql(u8, arg, "--flat")) opts.flat = true;
        if (std.mem.eql(u8, arg, "--check-files")) opts.check_files = true;
        if (std.mem.eql(u8, arg, "--ignore-scripts")) opts.ignore_scripts = true;
        if (std.mem.startsWith(u8, arg, "--concurrency=")) {
            opts.concurrency = std.fmt.parseInt(u32, arg["--concurrency=".len..], 10) catch opts.concurrency;
        }
    }

    return opts;
}
