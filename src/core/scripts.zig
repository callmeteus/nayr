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
/// Script output is captured.  Only `--verbose` or a non-zero exit code causes
/// stdout/stderr to be printed (Yarn Classic behaviour).
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `root_dir`: Project root (for resolving install paths).
/// - `hoisted`: The hoisted package layout.
/// - `build_git_deps`: When true, also run `prepare` (or `build` as fallback)
///   for git dependencies after their normal lifecycle scripts. This compiles
///   TypeScript packages that do not ship a pre-built `dist/`. Controlled by
///   `[git] build-deps = true` in `.nayrrc` or `NAYR_GIT_BUILD_DEPS=1`.
/// - `writer`: Output event sink.
pub fn runAll(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    hoisted: []const HoistedPackage,
    build_git_deps: bool,
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
                const result = runScript(allocator, script_cmd, pkg_dir, augmented_path, writer.isVerbose()) catch |err| {
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
                defer freeScriptResult(allocator, result);
                reportScriptRun(allocator, writer, hp.name, script_name, result);
            }
        }

        // Git dependencies: optionally run `prepare` (or `build` as fallback)
        // to compile the package. Controlled by `build_git_deps` (from config
        // `[git] build-deps = true` or env `NAYR_GIT_BUILD_DEPS=1`).
        if (build_git_deps and hp.pkg.is_git) {
            const prepare_script = manifest.scripts.get("prepare");
            const build_script = manifest.scripts.get("build");
            if (prepare_script orelse build_script) |script_cmd| {
                // Install the git dep's own node_modules before building.
                // Yarn classic does the same (runs `yarn install` in the clone
                // before `prepare`) so that devDependencies like `tsc` are
                // available when the build script runs.
                installGitDepDependencies(allocator, pkg_dir, augmented_path, hp.name, writer);

                const script_name = if (prepare_script != null) "prepare" else "build";

                const result = runScript(allocator, script_cmd, pkg_dir, augmented_path, writer.isVerbose()) catch |err| {
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
                defer freeScriptResult(allocator, result);
                reportScriptRun(allocator, writer, hp.name, script_name, result);
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
            const result = runScript(allocator, script_cmd, root_dir, augmented_path, writer.isVerbose()) catch |err| {
                const emsg = std.fmt.allocPrint(
                    allocator,
                    "script {s} [{s}] failed: {s}",
                    .{ script_name, pkg_name, @errorName(err) },
                ) catch continue;
                defer allocator.free(emsg);
                writer.emit(.{ .warning = emsg });
                continue;
            };
            defer freeScriptResult(allocator, result);
            reportScriptRun(allocator, writer, pkg_name, script_name, result);
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

/// Installs a git dependency's own `node_modules` by running the current nayr
/// binary with `install --ignore-scripts` inside `pkg_dir`.
///
/// This mirrors Yarn Classic behaviour: before running `prepare` on a git dep,
/// Yarn installs the dep's dependencies (including devDependencies needed for
/// compilation, e.g. `tsc`, `@clack/prompts`).
///
/// Errors are silenced - if the install fails the build step will surface the
/// missing module error with a clear message.
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `pkg_dir`: Absolute path to the installed git dep directory.
/// - `path_override`: Augmented PATH for child process.
/// - `name`: Package name (for warning messages).
/// - `writer`: Output event sink.
fn installGitDepDependencies(
    allocator: std.mem.Allocator,
    pkg_dir: []const u8,
    path_override: ?[]const u8,
    name: []const u8,
    writer: output.Writer,
) void {
    // Resolve the running nayr binary so we call exactly the same version.
    var self_buf: [4096]u8 = undefined;
    const self_path = std.fs.selfExePath(&self_buf) catch {
        writer.emit(.{ .warning = "git dep install: could not resolve nayr binary path" });
        return;
    };

    const argv = &[_][]const u8{ self_path, "install", "--ignore-scripts" };
    var child = std.process.Child.init(argv, allocator);
    child.cwd = pkg_dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    if (path_override) |p| {
        var env_map = std.process.getEnvMap(allocator) catch return;
        defer env_map.deinit();
        env_map.put("PATH", p) catch return;
        child.env_map = &env_map;
        child.spawn() catch return;
    } else {
        child.spawn() catch return;
    }
    _ = child.wait() catch {
        const wmsg = std.fmt.allocPrint(
            allocator,
            "git dep install failed for {s}",
            .{name},
        ) catch return;
        defer allocator.free(wmsg);
        writer.emit(.{ .warning = wmsg });
    };
}

/// Captured stdout/stderr from a lifecycle script invocation.
const ScriptResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

const script_output_cap: usize = 512 * 1024;

fn freeScriptResult(allocator: std.mem.Allocator, result: ScriptResult) void {
    if (result.stdout.len > 0) allocator.free(result.stdout);
    if (result.stderr.len > 0) allocator.free(result.stderr);
}

/// Emits script lifecycle events according to Yarn Classic rules.
fn reportScriptRun(
    allocator: std.mem.Allocator,
    writer: output.Writer,
    pkg_name: []const u8,
    script_name: []const u8,
    result: ScriptResult,
) void {
    const failed = result.exit_code != 0;
    const verbose = writer.isVerbose();
    const show_output = verbose or failed;

    if (verbose) {
        writer.emit(.{ .script_start = .{ .name = pkg_name, .script = script_name } });
    }

    if (show_output and (result.stdout.len > 0 or result.stderr.len > 0)) {
        writer.emit(.{ .script_output = .{
            .name = pkg_name,
            .stdout = result.stdout,
            .stderr = result.stderr,
        } });
    }

    if (failed) {
        const wmsg = std.fmt.allocPrint(
            allocator,
            "script {s} [{s}] exited with code {d}",
            .{ script_name, pkg_name, result.exit_code },
        ) catch return;
        defer allocator.free(wmsg);
        writer.emit(.{ .warning = wmsg });
    }
}

/// Runs a single script command in the given working directory.
///
/// stdout/stderr are captured.  Unless `verbose` is true, npm log env vars are
/// set so node-gyp and similar tools stay quiet on success.
fn runScript(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    cwd: []const u8,
    path_override: ?[]const u8,
    verbose: bool,
) !ScriptResult {
    const argv = if (@import("builtin").os.tag == .windows)
        &[_][]const u8{ "cmd.exe", "/c", cmd }
    else
        &[_][]const u8{ "/bin/sh", "-c", cmd };

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    if (path_override) |p| try env_map.put("PATH", p);
    if (!verbose) {
        try env_map.put("npm_config_loglevel", "silent");
        try env_map.put("npm_config_progress", "false");
    }

    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |err| {
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

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, script_output_cap);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, script_output_cap);
    errdefer allocator.free(stderr);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };

    return ScriptResult{
        .exit_code = exit_code,
        .stdout = stdout,
        .stderr = stderr,
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
