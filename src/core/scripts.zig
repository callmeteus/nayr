//! Lifecycle Script Runner
//!
//! Executes npm lifecycle scripts (preinstall, install, postinstall) for
//! packages that declare them. Scripts run sequentially in dependency order
//! - this is a requirement of the npm ecosystem because some scripts expect
//! their dependencies to already be installed.

const std = @import("std");
const platform = @import("../util/platform.zig");
const json_util = @import("../util/json.zig");
const output = @import("../util/output.zig");
const hoister = @import("hoister.zig");
const HoistedPackage = hoister.HoistedPackage;

// ============================================================================
// Public API
// ============================================================================

/// Runs lifecycle scripts for all hoisted packages that declare them.
///
/// Execution order respects the dependency tree depth (post-order traversal):
/// deepest dependencies run first so that a package's deps are ready when its
/// own postinstall fires.
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `root_dir`: Project root (for resolving install paths).
/// - `hoisted`: The hoisted package layout.
/// - `writer`: Output event sink.
/// - `verbose`: When true, script stdout/stderr is shown.
pub fn runAll(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    hoisted: []const HoistedPackage,
    writer: output.Writer,
    verbose: bool,
) !void {
    for (hoisted) |hp| {
        if (hp.pkg.is_workspace) continue; // workspace scripts are run by the user

        const pkg_dir = try std.fs.path.join(allocator, &.{ root_dir, hp.install_path });
        defer allocator.free(pkg_dir);

        const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, "package.json" });
        defer allocator.free(manifest_path);

        var manifest = json_util.parseFile(allocator, manifest_path) catch continue;
        defer manifest.deinit(allocator);

        for (lifecycle_scripts) |script_name| {
            if (manifest.scripts.get(script_name)) |script_cmd| {
                writer.emit(.{ .script_start = .{ .name = hp.name, .script = script_name } });

                const exit_code = runScript(allocator, script_cmd, pkg_dir, verbose) catch |err| {
                    writer.emit(.{ .warning = try std.fmt.allocPrint(
                        allocator,
                        "script {s} [{s}] failed: {s}",
                        .{ script_name, hp.name, @errorName(err) },
                    ) });
                    continue;
                };

                if (exit_code != 0) {
                    writer.emit(.{ .warning = try std.fmt.allocPrint(
                        allocator,
                        "script {s} [{s}] exited with code {d}",
                        .{ script_name, hp.name, exit_code },
                    ) });
                }
            }
        }
    }
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Lifecycle scripts run in this order.
const lifecycle_scripts = [_][]const u8{
    "preinstall",
    "install",
    "postinstall",
};

/// Runs a single script command in the given working directory.
fn runScript(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    cwd: []const u8,
    verbose: bool,
) !u8 {
    var child = std.process.Child.init(
        if (@import("builtin").os.tag == .windows)
            &[_][]const u8{ "cmd.exe", "/c", cmd }
        else
            &[_][]const u8{ "/bin/sh", "-c", cmd },
        allocator,
    );
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = if (verbose) .Inherit else .Ignore;
    child.stderr_behavior = if (verbose) .Inherit else .Ignore;
    const result = try child.spawnAndWait();
    return switch (result) {
        .Exited => |code| code,
        else => 1,
    };
}
