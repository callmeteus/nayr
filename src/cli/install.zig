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
    concurrency: u32 = 16,
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
