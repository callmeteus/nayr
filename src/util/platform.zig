//! Platform Abstraction Layer
//!
//! Provides a uniform interface over OS-specific filesystem and process
//! operations. All platform-divergent code lives here so the rest of nayr
//! stays portable without #ifdef noise.
//!
//! Supported targets:
//!   - x86_64-linux-gnu
//!   - aarch64-linux-gnu
//!   - x86_64-windows-gnu

const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const scripts = @import("../core/scripts.zig");

// ============================================================================
// Directory paths
// ============================================================================

/// Returns the global nayr cache directory.
///
/// Linux/macOS: `$XDG_CACHE_HOME/nayr` or `~/.nayr/cache`
/// Windows:     `%LOCALAPPDATA%\nayr\cache`
pub fn getCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const local_appdata = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch
            return error.MissingEnvVar;
        defer allocator.free(local_appdata);
        return std.fs.path.join(allocator, &.{ local_appdata, "nayr", "cache" });
    }

    // Respect XDG_CACHE_HOME if set.
    if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "nayr" });
    } else |_| {}

    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".nayr", "cache" });
}

/// Returns the global nayr config directory.
///
/// Linux/macOS: `$XDG_CONFIG_HOME/nayr` or `~/.nayr`
/// Windows:     `%APPDATA%\nayr`
pub fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch
            return error.MissingEnvVar;
        defer allocator.free(appdata);
        return std.fs.path.join(allocator, &.{ appdata, "nayr" });
    }

    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "nayr" });
    } else |_| {}

    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".nayr" });
}

/// Returns the global nayr package installation directory.
///
/// This is the "home" of globally installed packages - equivalent to
/// `yarn global dir`.  nayr maintains a `package.json` here that records
/// which packages the user has installed globally, plus a standard
/// `node_modules/` tree populated by `nayr install`.
///
/// Linux/macOS: `~/.nayr/global`
/// Windows:     `%APPDATA%\nayr\global`
pub fn getGlobalDir(allocator: std.mem.Allocator) ![]const u8 {
    const config = try getConfigDir(allocator);
    defer allocator.free(config);
    return std.fs.path.join(allocator, &.{ config, "global" });
}

/// Returns the directory where global binary stubs are written.
///
/// After `nayr global add <pkg>`, nayr symlinks every binary declared in the
/// package's `bin` field into this directory.  Users should add it to PATH.
///
/// Linux/macOS: `~/.nayr/bin`
/// Windows:     `%APPDATA%\nayr\bin`
pub fn getGlobalBinDir(allocator: std.mem.Allocator) ![]const u8 {
    const config = try getConfigDir(allocator);
    defer allocator.free(config);
    return std.fs.path.join(allocator, &.{ config, "bin" });
}

/// Returns the global nayr links registry directory.
///
/// Linux/macOS: `~/.nayr/links`
/// Windows:     `%APPDATA%\nayr\links`
pub fn getLinksDir(allocator: std.mem.Allocator) ![]const u8 {
    const config = try getConfigDir(allocator);
    defer allocator.free(config);
    return std.fs.path.join(allocator, &.{ config, "links" });
}

/// Returns Yarn Classic's global link registry directory, if it can be found.
///
/// Yarn 1.x stores links at:
///   Linux/macOS: `$XDG_CONFIG_HOME/yarn/link` or `~/.config/yarn/link`
///   Windows:     `%LOCALAPPDATA%\Yarn\Data\link`
///
/// Returns `error.NotFound` when the directory does not exist.
pub fn getYarnLinksDir(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const local = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch
            return error.NotFound;
        defer allocator.free(local);
        const path = try std.fs.path.join(allocator, &.{ local, "Yarn", "Data", "link" });
        std.fs.accessAbsolute(path, .{}) catch {
            allocator.free(path);
            return error.NotFound;
        };
        return path;
    }

    // XDG_CONFIG_HOME / ~/.config
    const config_base: []const u8 = blk: {
        if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
            break :blk xdg;
        } else |_| {}
        const home = getHomeDir(allocator) catch return error.NotFound;
        defer allocator.free(home);
        break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
    };
    defer allocator.free(config_base);

    const path = try std.fs.path.join(allocator, &.{ config_base, "yarn", "link" });
    std.fs.accessAbsolute(path, .{}) catch {
        allocator.free(path);
        return error.NotFound;
    };
    return path;
}

/// Reads a symlink and resolves its target to an absolute path.
///
/// Yarn stores relative targets; this function returns the resolved absolute
/// path. Caller owns the returned slice.
pub fn readSymlinkAbsolute(allocator: std.mem.Allocator, link_path: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const raw = try std.fs.readLinkAbsolute(link_path, &buf);
    if (std.fs.path.isAbsolute(raw)) {
        return allocator.dupe(u8, raw);
    }
    // Resolve relative target against the symlink's parent directory.
    const parent = std.fs.path.dirname(link_path) orelse ".";
    return std.fs.path.resolve(allocator, &.{ parent, raw });
}

/// Returns the user's home directory.
pub fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        return std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
            std.process.getEnvVarOwned(allocator, "HOMEDRIVE");
    }
    return std.process.getEnvVarOwned(allocator, "HOME") catch error.MissingHomeEnv;
}

// ============================================================================
// Filesystem operations
// ============================================================================

/// Creates a symbolic link, with a junction-point fallback on Windows.
///
/// On POSIX, calls `symlink(target, link_path)`.
/// On Windows, calls `CreateSymbolicLinkW`. If that fails due to missing
/// privileges, falls back to `CreateJunctionPoint` for directories.
///
/// ## Parameters
/// - `target`: The path the symlink should point to.
/// - `link_path`: Where the symlink (or junction) will be created.
pub fn symlinkOrJunction(target: []const u8, link_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        // On Windows, symlinks require elevated privileges or Developer Mode.
        // For directories we fall back to NTFS junction points, which do not
        // require special rights and are transparent to most tooling.
        fs.symLinkAbsolute(target, link_path, .{ .is_directory = true }) catch {
            return createJunction(target, link_path);
        };
        return;
    }
    try fs.symLinkAbsolute(target, link_path, .{});
}

/// Creates a hard link, falling back to a full copy if hard links are not
/// supported (e.g., cross-device moves, FAT32 targets).
///
/// ## Parameters
/// - `src`: Source file path.
/// - `dest`: Destination path for the hard link or copy.
pub fn hardlinkOrCopy(src: []const u8, dest: []const u8) !void {
    if (builtin.os.tag == .windows) {
        // Hard links on Windows require NTFS and same-volume constraints;
        // skip straight to a plain copy for simplicity and reliability.
        try copyFile(src, dest);
        return;
    }
    std.posix.link(src, dest) catch {
        // Hard link failed (e.g., cross-device) - copy the file instead.
        try copyFile(src, dest);
    };
}

/// Performs an optimised file copy.
///
/// On Linux, uses `copy_file_range(2)` for zero-copy kernel-side transfer.
/// On Windows, delegates to `CopyFileW`.
/// On other POSIX, falls back to a buffered read/write loop.
///
/// ## Parameters
/// - `src`: Source file path.
/// - `dest`: Destination file path.
pub fn copyFile(src: []const u8, dest: []const u8) !void {
    if (builtin.os.tag == .linux) {
        return copyFileLinux(src, dest);
    }
    // Generic fallback: preserve source permissions then copy content.
    const src_file = try fs.openFileAbsolute(src, .{});
    defer src_file.close();
    const stat = try src_file.stat();
    const dest_file = try fs.createFileAbsolute(dest, .{ .mode = stat.mode });
    defer dest_file.close();
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try src_file.read(&buf);
        if (n == 0) break;
        try dest_file.writeAll(buf[0..n]);
    }
}

/// Atomically replace `dest` with `src` using a rename.
///
/// On POSIX, `rename(2)` is atomic within the same filesystem.
/// On Windows, uses `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`.
///
/// This is the cornerstone of nayr's lock-free cache design: writers
/// always write to a temp path then rename into place, so readers never
/// observe a partial state.
///
/// ## Parameters
/// - `src`: Temporary file/directory path.
/// - `dest`: Final destination path.
pub fn atomicRename(src: []const u8, dest: []const u8) !void {
    try std.fs.renameAbsolute(src, dest);
}

/// Creates a `.cmd` wrapper stub on Windows for a bin entry, or a symlink
/// on POSIX.
///
/// npm/Yarn create `.cmd` files on Windows because symlinks to script files
/// do not work with `cmd.exe`. The stub simply delegates to `node` with the
/// original script path.
///
/// ## Parameters
/// - `bin_dir`: Path to the `.bin/` directory.
/// - `name`: Binary name (without extension).
/// - `target`: Absolute path to the target script.
pub fn createBinStub(allocator: std.mem.Allocator, bin_dir: []const u8, name: []const u8, target: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const stub_path = try std.fs.path.join(allocator, &.{ bin_dir, try std.fmt.allocPrint(allocator, "{s}.cmd", .{name}) });
        defer allocator.free(stub_path);
        const file = try fs.createFileAbsolute(stub_path, .{});
        defer file.close();
        // A minimal .cmd stub that forwards all arguments to `node`.
        try file.writer().print("@node \"{s}\" %*\r\n", .{target});
        return;
    }

    // POSIX: create a symlink from .bin/<name> -> <target>
    const link_path = try std.fs.path.join(allocator, &.{ bin_dir, name });
    defer allocator.free(link_path);

    // Remove any existing entry. deleteFileAbsolute removes files and symlinks
    // but fails for directories; deleteTreeAbsolute handles all cases.
    fs.deleteFileAbsolute(link_path) catch {
        fs.deleteTreeAbsolute(link_path) catch {};
    };

    // Ensure the target file is executable. npm tarballs frequently omit the
    // execute bit on .js binaries even when they declare a shebang; the shell
    // refuses to run them ("Permission denied") unless we set +x here.
    if (fs.openFileAbsolute(target, .{})) |f| {
        defer f.close();
        f.chmod(0o755) catch {};
    } else |_| {}

    // Compute a relative target path from bin_dir to target.
    // Relative symlinks are portable (survive project directory moves) and
    // match the behaviour of Yarn Classic and npm.
    // Use std.posix.symlink directly because symLinkAbsolute asserts the target
    // is absolute, but relative symlink targets are intentionally not absolute.
    const rel_target = fs.path.relative(allocator, bin_dir, target) catch null;
    defer if (rel_target) |r| allocator.free(r);
    const sym_target = if (rel_target) |r| r else target;

    try std.posix.symlink(sym_target, link_path);
}

/// Runs a shell command string using the platform's native shell, with
/// `node_modules/.bin` prepended to PATH so that locally-installed binaries
/// are always resolvable inside scripts.
///
/// Linux/macOS: `PATH=<cwd>/node_modules/.bin:$PATH /bin/sh -c <cmd>`
/// Windows:     `cmd.exe /c <cmd>` (with PATH mutation via env_map)
///
/// ## Parameters
/// - `allocator`: Allocator for argument arrays and env map.
/// - `cmd`: Shell command string to execute (may contain shell operators).
/// - `cwd`: Working directory for the child process.
///
/// ## Returns
/// The process exit code (0 = success).
pub fn runScript(allocator: std.mem.Allocator, cmd: []const u8, cwd: []const u8) !u8 {
    return runScriptWithArgs(allocator, cmd, cwd, &.{});
}

/// Like `runScript` but appends `extra_args` to the command string.
///
/// Extra args are shell-escaped and appended after the script body so that
/// `nayr build -- --watch` correctly passes `--watch` to the script command.
pub fn runScriptWithArgs(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    cwd: []const u8,
    extra_args: []const []const u8,
) !u8 {
    // Build the full command, appending any extra args.
    const full_cmd = if (extra_args.len > 0) blk: {
        var parts = std.ArrayList([]const u8).init(allocator);
        defer parts.deinit();
        try parts.append(cmd);
        for (extra_args) |a| try parts.append(a);
        break :blk try std.mem.join(allocator, " ", parts.items);
    } else try allocator.dupe(u8, cmd);
    defer allocator.free(full_cmd);

    // Build child argv.
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/c", full_cmd }
    else
        &.{ "/bin/sh", "-c", full_cmd };

    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    // Inject ~/.nayr/shims (yarn -> nayr shim) and node_modules/.bin into PATH
    // so that any `yarn` call inside scripts is transparently handled by nayr.
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    const new_path = try scripts.buildScriptPath(allocator, cwd);
    defer allocator.free(new_path);
    try env_map.put("PATH", new_path);
    child.env_map = &env_map;

    const result = try child.spawnAndWait();
    return switch (result) {
        .Exited => |code| code,
        else => 1,
    };
}

/// Runs a binary directly (no shell) with explicit argv.
///
/// Used when `nayr <name>` resolves to a binary in `node_modules/.bin` rather
/// than a script entry in `package.json`.
///
/// ## Parameters
/// - `allocator`: Allocator for argument arrays.
/// - `bin_path`: Absolute path to the executable.
/// - `args`: Arguments to pass (does NOT include the binary path at index 0).
/// - `cwd`: Working directory for the child process.
///
/// ## Returns
/// The process exit code.
pub fn runBinary(
    allocator: std.mem.Allocator,
    bin_path: []const u8,
    args: []const []const u8,
    cwd: []const u8,
) !u8 {
    const bin_dir = try std.fs.path.join(allocator, &.{ cwd, "node_modules", ".bin" });
    defer allocator.free(bin_dir);

    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(bin_path);
    try argv.appendSlice(args);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    // Inject node_modules/.bin into PATH.
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    if (env_map.get("PATH")) |old_path| {
        const new_path = try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{
            bin_dir,
            std.fs.path.delimiter,
            old_path,
        });
        defer allocator.free(new_path);
        try env_map.put("PATH", new_path);
    } else {
        try env_map.put("PATH", bin_dir);
    }
    child.env_map = &env_map;

    const result = try child.spawnAndWait();
    return switch (result) {
        .Exited => |code| code,
        else => 1,
    };
}

/// Returns true when `stdout` is connected to a TTY (interactive terminal).
///
/// Used by the output module to decide whether to render TUI or plain text.
pub fn isStdoutTty() bool {
    if (builtin.os.tag == .windows) {
        // On Windows, check the console mode flag.
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch return false;
        var mode: std.os.windows.DWORD = 0;
        return std.os.windows.kernel32.GetConsoleMode(handle, &mode) != 0;
    }
    return std.posix.isatty(std.io.getStdOut().handle);
}

/// Returns the terminal width in columns, or a sensible default (80).
pub fn terminalWidth() u16 {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        // SAFETY: `ioctl(TIOCGWINSZ)` fully initializes `ws` when it returns 0.
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(
            std.io.getStdOut().handle,
            std.posix.T.IOCGWINSZ,
            @intFromPtr(&ws),
        );
        if (rc == 0 and ws.col > 0) return ws.col;
    }
    return 80;
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Linux-specific zero-copy file copy using `copy_file_range(2)`.
fn copyFileLinux(src: []const u8, dest: []const u8) !void {
    const src_file = try fs.openFileAbsolute(src, .{});
    defer src_file.close();
    const stat = try src_file.stat();

    // Preserve the source file's permission bits (including the executable bit).
    const dest_file = try fs.createFileAbsolute(dest, .{ .mode = stat.mode });
    defer dest_file.close();

    var offset_in: u64 = 0;
    var remaining = stat.size;

    while (remaining > 0) {
        // copy_file_range may transfer less than requested; loop until done.
        const transferred = try std.posix.copy_file_range(
            src_file.handle,
            offset_in,
            dest_file.handle,
            offset_in,
            remaining,
            0,
        );
        if (transferred == 0) break;
        offset_in += transferred;
        remaining -= transferred;
    }
}

/// Windows-specific junction point creation (directory symlink without UAC).
fn createJunction(target: []const u8, link_path: []const u8) !void {
    // Junction points are Windows-only and are created via DeviceIoControl.
    // This is a simplified implementation - in production, use ReparsePoint API.
    _ = target;
    _ = link_path;
    return error.JunctionNotImplemented;
}
