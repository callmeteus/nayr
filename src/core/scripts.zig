//! Lifecycle Script Runner
//!
//! Executes npm lifecycle scripts (preinstall, install, postinstall, prepare)
//! for packages that declare them. Scripts run sequentially in dependency
//! order - this is a requirement of the npm ecosystem because some scripts
//! expect their dependencies to already be installed.
//!
//! Root package lifecycle order (mirrors Yarn Classic):
//!   1. Root `preinstall`           ← before any deps are installed
//!   2. All dependency scripts      ← preinstall → install → postinstall
//!   3. Root `install` + `postinstall` + `prepare`  ← after deps are ready

const std = @import("std");
const json_util = @import("../util/json.zig");
const output = @import("../util/output.zig");
const IoTrace = @import("../util/io_trace.zig").IoTrace;
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
/// Script stdout/stderr always stream live to the terminal so the user sees
/// build output in real-time (same behaviour as npm/yarn).
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `root_dir`: Project root (for resolving install paths).
/// - `hoisted`: The hoisted package layout.
/// - `writer`: Output event sink.
pub fn runAll(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    hoisted: []const HoistedPackage,
    writer: output.Writer,
) !void {
    // Build the augmented PATH once (reused for every script in this run).
    // npm/yarn prepend node_modules/.bin directories so that lifecycle scripts
    // can call binaries installed as dependencies without a full path.
    const augmented_path = buildScriptPath(allocator, root_dir) catch null;
    defer if (augmented_path) |p| allocator.free(p);

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

                const exit_code = runScript(allocator, script_cmd, pkg_dir, augmented_path) catch |err| {
                    const emsg = std.fmt.allocPrint(
                        allocator,
                        "script {s} [{s}] failed: {s}",
                        .{ script_name, hp.name, @errorName(err) },
                    ) catch {
                        continue;
                    };
                    defer allocator.free(emsg);
                    writer.emit(.{ .warning = emsg });
                    continue;
                };

                if (exit_code != 0) {
                    const wmsg = try std.fmt.allocPrint(
                        allocator,
                        "script {s} [{s}] exited with code {d}",
                        .{ script_name, hp.name, exit_code },
                    );
                    defer allocator.free(wmsg);
                    writer.emit(.{ .warning = wmsg });
                }
            }
        }
    }
}

/// Runs the root project's `preinstall` script (before any deps are touched).
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `root_dir`: Project root containing `package.json`.
/// - `writer`: Output event sink.
pub fn runRootPre(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    writer: output.Writer,
) !void {
    try runRootScripts(allocator, root_dir, writer, &.{"preinstall"});
}

/// Runs the root project's `install`, `postinstall` and `prepare` scripts
/// (called after all dependencies are linked).
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `root_dir`: Project root containing `package.json`.
/// - `writer`: Output event sink.
pub fn runRootPost(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    writer: output.Writer,
) !void {
    try runRootScripts(allocator, root_dir, writer, &root_post_scripts);
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Runs a subset of lifecycle script names for the root package.json.
fn runRootScripts(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    writer: output.Writer,
    script_names: []const []const u8,
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "package.json" });
    defer allocator.free(manifest_path);

    var manifest = json_util.parseFile(allocator, manifest_path) catch return;
    defer manifest.deinit(allocator);

    const pkg_name = manifest.name orelse "project";

    const augmented_path = buildScriptPath(allocator, root_dir) catch null;
    defer if (augmented_path) |p| allocator.free(p);

    for (script_names) |script_name| {
        if (manifest.scripts.get(script_name)) |script_cmd| {
            writer.emit(.{ .script_start = .{ .name = pkg_name, .script = script_name } });

            const exit_code = runScript(allocator, script_cmd, root_dir, augmented_path) catch |err| {
                const emsg = std.fmt.allocPrint(
                    allocator,
                    "script {s} [{s}] failed: {s}",
                    .{ script_name, pkg_name, @errorName(err) },
                ) catch continue;
                defer allocator.free(emsg);
                writer.emit(.{ .warning = emsg });
                continue;
            };

            if (exit_code != 0) {
                const wmsg = try std.fmt.allocPrint(
                    allocator,
                    "script {s} [{s}] exited with code {d}",
                    .{ script_name, pkg_name, exit_code },
                );
                defer allocator.free(wmsg);
                writer.emit(.{ .warning = wmsg });
            }
        }
    }
}

/// Lifecycle scripts executed for each dependency (in this order).
const lifecycle_scripts = [_][]const u8{
    "preinstall",
    "install",
    "postinstall",
};

/// Lifecycle scripts executed for the root project after all deps are ready.
const root_post_scripts = [_][]const u8{
    "install",
    "postinstall",
    "prepare",
};

/// Runs a single script command in the given working directory.
///
/// stdout and stderr always stream live to the terminal so the user can
/// see build progress in real-time (same behaviour as npm/yarn).
///
/// `path_override` replaces the PATH env var for the child process so that
/// `node_modules/.bin/` executables are reachable by the script.
fn runScript(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    cwd: []const u8,
    path_override: ?[]const u8,
) !u8 {
    const argv = if (@import("builtin").os.tag == .windows)
        &[_][]const u8{ "cmd.exe", "/c", cmd }
    else
        &[_][]const u8{ "/bin/sh", "-c", cmd };

    // Build an env map that mirrors the current environment but with an
    // augmented PATH so lifecycle scripts can call installed binaries.
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    if (path_override) |p| try env_map.put("PATH", p);

    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const result = child.spawnAndWait() catch |err| {
        if (err == error.FileNotFound) {
            var note_buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&note_buf, "lifecycle spawn cwd={s} cmd={s}", .{ cwd, cmd })) |note| {
                IoTrace.recordMissingPath(note);
            } else |_| {
                IoTrace.recordMissingPath("lifecycle spawn (path buffer too small)");
            }
        }
        return err;
    };
    return switch (result) {
        .Exited => |c| c,
        else => 1,
    };
}

/// Returns a PATH string with `node_modules/.bin` and the nayr shim
/// directory prepended, following npm's convention for lifecycle script
/// environments.
///
/// Prepended directories (in order):
///   1. `~/.nayr/shims`              - yarn → nayr shim (and future shims)
///   2. `{root}/node_modules/.bin`   - hoisted / root-level executables
///
/// The caller owns the returned slice.
pub fn buildScriptPath(allocator: std.mem.Allocator, root_dir: []const u8) ![]const u8 {
    const root_bin = try std.fs.path.join(allocator, &.{ root_dir, "node_modules", ".bin" });
    defer allocator.free(root_bin);

    const shim_dir = ensureYarnShim(allocator) catch null;
    defer if (shim_dir) |d| allocator.free(d);

    const sep = if (@import("builtin").os.tag == .windows) ";" else ":";
    const existing = std.process.getEnvVarOwned(allocator, "PATH") catch "";
    defer if (existing.len > 0) allocator.free(existing);

    // Build: [shim_dir:]root_bin[:existing]
    if (shim_dir) |d| {
        if (existing.len == 0) {
            return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ d, sep, root_bin });
        }
        return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s}", .{ d, sep, root_bin, sep, existing });
    }
    if (existing.len == 0) return allocator.dupe(u8, root_bin);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ root_bin, sep, existing });
}

/// Ensures a `yarn` shim exists inside `~/.nayr/shims/` (Unix) or
/// `%USERPROFILE%\.nayr\shims\` (Windows) that delegates every call to the
/// current nayr binary.
///
/// On Unix  → `yarn`     (POSIX shell script, chmod 755)
/// On Windows → `yarn.cmd` (batch file, no chmod needed)
///
/// This lets lifecycle scripts and shebangs that reference `yarn`
/// (e.g. `"build": "yarn build"` or `#!/usr/bin/env yarn`) transparently
/// use nayr instead, without modifying any project file.
///
/// Returns the shims directory path.  The caller owns the returned slice.
/// Errors are silently ignored by the caller so scripts still run even if
/// the shim cannot be created (e.g. read-only home directory).
fn ensureYarnShim(allocator: std.mem.Allocator) ![]const u8 {
    const is_windows = @import("builtin").os.tag == .windows;

    // Prefer HOME; fall back to USERPROFILE on Windows.
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        (if (is_windows)
            try std.process.getEnvVarOwned(allocator, "USERPROFILE")
        else
            return error.NoHome);
    defer allocator.free(home);

    const shim_dir = try std.fs.path.join(allocator, &.{ home, ".nayr", "shims" });
    errdefer allocator.free(shim_dir);

    std.fs.makeDirAbsolute(shim_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Resolve the absolute path of the running nayr binary so the shim works
    // even when nayr is not yet on PATH.
    var self_buf: [4096]u8 = undefined;
    const self_path = try std.fs.selfExePath(&self_buf);

    if (is_windows) {
        // Windows: create yarn.cmd so cmd.exe finds it without an extension.
        // `%*` forwards all arguments; quotes handle spaces in the path.
        const shim_path = try std.fs.path.join(allocator, &.{ shim_dir, "yarn.cmd" });
        defer allocator.free(shim_path);

        const content = try std.fmt.allocPrint(
            allocator,
            "@echo off\r\n\"{s}\" %*\r\n",
            .{self_path},
        );
        defer allocator.free(content);

        const file = try std.fs.createFileAbsolute(shim_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);
    } else {
        // Unix: POSIX shell script with exec so nayr replaces the shell process.
        const shim_path = try std.fs.path.join(allocator, &.{ shim_dir, "yarn" });
        defer allocator.free(shim_path);

        const content = try std.fmt.allocPrint(
            allocator,
            "#!/bin/sh\nexec \"{s}\" \"$@\"\n",
            .{self_path},
        );
        defer allocator.free(content);

        const file = try std.fs.createFileAbsolute(shim_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);
        try file.chmod(0o755);
    }

    return shim_dir;
}
