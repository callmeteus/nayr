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
const fs_util = @import("../util/fs.zig");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
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

    const hoisted = try hoister_mod.hoist(allocator, &resolution.packages, &checker);
    defer {
        for (hoisted) |hp| allocator.free(hp.install_path);
        allocator.free(hoisted);
    }

    // Build workspace name → path map for the linker.
    var ws_paths = std.StringHashMapUnmanaged([]const u8){};
    defer ws_paths.deinit(allocator);
    for (workspaces) |*ws| {
        const name = ws.manifest.name orelse continue;
        try ws_paths.put(allocator, name, ws.path);
    }

    // --- Phase 4: Link ---
    writer.emit(.{ .info = "Linking packages..." });
    try linker_mod.link(allocator, cwd, hoisted, &cache, &ws_paths, writer);

    // --- Phase 4.5: Apply registered links (nayr + yarn fallback) ---
    // Any package that has a local link registered (via `nayr link` or inherited
    // from Yarn Classic) overrides the cache-backed symlink with a direct pointer
    // to the development checkout.
    try applyRegisteredLinks(allocator, cwd, hoisted, writer);

    // --- Phase 5: Scripts ---
    if (!opts.ignore_scripts and !config.ignore_scripts) {
        writer.emit(.{ .info = "Running lifecycle scripts..." });
        try scripts_mod.runAll(allocator, cwd, hoisted, writer, false);
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
// Registered-links application
// ============================================================================

/// After the normal link phase, override any installed package whose name is
/// registered in the nayr (or Yarn Classic) link registry with a symlink that
/// points directly to the development checkout.
///
/// This mirrors Yarn Classic's behaviour: `yarn install` automatically honours
/// `yarn link`-registered packages so developers never need a separate step.
fn applyRegisteredLinks(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    hoisted: []const hoister_mod.HoistedPackage,
    writer: output.Writer,
) !void {
    // Use an arena for all temporary allocations inside this function.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build a name → install_path map so look-ups are O(1).
    var name_to_path = std.StringHashMapUnmanaged([]const u8){};
    for (hoisted) |hp| {
        if (hp.pkg.is_workspace) continue; // workspace packages need no override
        try name_to_path.put(arena, hp.name, hp.install_path);
    }

    const nayr_links_dir = platform.getLinksDir(allocator) catch return;
    defer allocator.free(nayr_links_dir);

    // Walk nayr's registry, then fall back to Yarn's.
    // We collect two sources: (1) nayr links dir, (2) yarn links dir entries
    // not already in nayr.

    var applied: u32 = 0;

    // Helper: given a link registry dir and a package name found inside it,
    // override the node_modules entry with a symlink.
    const apply = struct {
        fn do(
            alloc: std.mem.Allocator,
            project_root: []const u8,
            link_entry_path: []const u8, // full path to the link registry entry
            pkg_name: []const u8,
            install_path_rel: []const u8, // e.g. "node_modules/@luckymaker/shared"
            counter: *u32,
            w: output.Writer,
        ) !void {
            // Read the symlink target (resolves relative paths).
            const target = platform.readSymlinkAbsolute(alloc, link_entry_path) catch return;

            // Build absolute install path.
            const dest = try std.fs.path.join(alloc, &.{ project_root, install_path_rel });

            // Ensure scope dir exists.
            if (pkg_name[0] == '@') {
                const slash = std.mem.indexOfScalar(u8, pkg_name, '/') orelse return;
                const scope_nm = try std.fs.path.join(alloc, &.{
                    project_root, install_path_rel[0 .. "node_modules/".len + (slash + 1)],
                });
                fs_util.mkdirAllRecursive(alloc, scope_nm) catch {};
            }

            // Replace whatever the linker placed there with the dev checkout.
            std.fs.deleteTreeAbsolute(dest) catch {};
            std.fs.deleteFileAbsolute(dest) catch {};
            platform.symlinkOrJunction(target, dest) catch |err| {
                const wmsg = std.fmt.allocPrint(alloc, "could not apply link for {s}: {s}", .{ pkg_name, @errorName(err) }) catch return;
                w.emit(.{ .warning = wmsg });
                return;
            };

            counter.* += 1;
            const msg = std.fmt.allocPrint(
                alloc,
                "linked: {s} → {s}",
                .{ pkg_name, target },
            ) catch return;
            w.emit(.{ .info = msg });
        }
    };

    // Walk nayr links dir.
    try walkAndApply(arena, cwd, nayr_links_dir, &name_to_path, &applied, writer, apply.do);

    // Walk Yarn links dir (skip packages already handled by nayr).
    const yarn_dir = platform.getYarnLinksDir(allocator) catch null;
    if (yarn_dir) |yd| {
        defer allocator.free(yd);

        // Build a set of names already applied from nayr's registry.
        var already = std.StringHashMapUnmanaged(void){};
        try walkLinksCollectNames(arena, nayr_links_dir, &already);

        // Walk yarn dir, apply only what nayr hasn't covered.
        var dir = std.fs.openDirAbsolute(yd, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .sym_link) {
                if (already.contains(entry.name)) continue;
                const install_path = name_to_path.get(entry.name) orelse continue;
                const link_entry = try std.fs.path.join(arena, &.{ yd, entry.name });
                try apply.do(arena, cwd, link_entry, entry.name, install_path, &applied, writer);
            } else if (entry.kind == .directory and entry.name[0] == '@') {
                const scope_path = try std.fs.path.join(arena, &.{ yd, entry.name });
                var scope_dir = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch continue;
                defer scope_dir.close();
                var sit = scope_dir.iterate();
                while (try sit.next()) |se| {
                    if (se.kind != .sym_link) continue;
                    const scoped = try std.fmt.allocPrint(arena, "{s}/{s}", .{ entry.name, se.name });
                    if (already.contains(scoped)) continue;
                    const install_path = name_to_path.get(scoped) orelse continue;
                    const link_entry = try std.fs.path.join(arena, &.{ scope_path, se.name });
                    try apply.do(arena, cwd, link_entry, scoped, install_path, &applied, writer);
                }
            }
        }
    }

}

/// Walks a link registry directory (depth-2 for scoped packages) and calls
/// `apply_fn` for every link whose name exists in `name_to_path`.
fn walkAndApply(
    arena: std.mem.Allocator,
    cwd: []const u8,
    links_dir: []const u8,
    name_to_path: *const std.StringHashMapUnmanaged([]const u8),
    counter: *u32,
    writer: output.Writer,
    comptime apply_fn: fn (
        std.mem.Allocator,
        []const u8,
        []const u8,
        []const u8,
        []const u8,
        *u32,
        output.Writer,
    ) anyerror!void,
) !void {
    var dir = std.fs.openDirAbsolute(links_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .sym_link) {
            const install_path = name_to_path.get(entry.name) orelse continue;
            const link_entry = try std.fs.path.join(arena, &.{ links_dir, entry.name });
            try apply_fn(arena, cwd, link_entry, entry.name, install_path, counter, writer);
        } else if (entry.kind == .directory and entry.name[0] == '@') {
            const scope_path = try std.fs.path.join(arena, &.{ links_dir, entry.name });
            var scope_dir = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch continue;
            defer scope_dir.close();
            var sit = scope_dir.iterate();
            while (try sit.next()) |se| {
                if (se.kind != .sym_link) continue;
                const scoped = try std.fmt.allocPrint(arena, "{s}/{s}", .{ entry.name, se.name });
                const install_path = name_to_path.get(scoped) orelse continue;
                const link_entry = try std.fs.path.join(arena, &.{ scope_path, se.name });
                try apply_fn(arena, cwd, link_entry, scoped, install_path, counter, writer);
            }
        }
    }
}

/// Collects all package names registered in `links_dir` into `out`.
fn walkLinksCollectNames(
    arena: std.mem.Allocator,
    links_dir: []const u8,
    out: *std.StringHashMapUnmanaged(void),
) !void {
    var dir = std.fs.openDirAbsolute(links_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .sym_link) {
            try out.put(arena, entry.name, {});
        } else if (entry.kind == .directory and entry.name[0] == '@') {
            const scope_path = try std.fs.path.join(arena, &.{ links_dir, entry.name });
            var sd = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch continue;
            defer sd.close();
            var sit = sd.iterate();
            while (try sit.next()) |se| {
                if (se.kind != .sym_link) continue;
                const scoped = try std.fmt.allocPrint(arena, "{s}/{s}", .{ entry.name, se.name });
                try out.put(arena, scoped, {});
            }
        }
    }
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
