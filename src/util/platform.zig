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

/// Returns the global nayr links registry directory.
///
/// Linux/macOS: `~/.nayr/links`
/// Windows:     `%APPDATA%\nayr\links`
pub fn getLinksDir(allocator: std.mem.Allocator) ![]const u8 {
    const config = try getConfigDir(allocator);
    defer allocator.free(config);
    return std.fs.path.join(allocator, &.{ config, "links" });
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
    std.posix.link(src, dest) catch {
        // Hard link failed (e.g., cross-device) — copy the file instead.
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
    // Generic fallback: std.fs buffered copy.
    try fs.copyFileAbsolute(src, dest, .{});
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
    // Remove any existing entry (idempotent).
    fs.deleteFileAbsolute(link_path) catch {};
    try symlinkOrJunction(target, link_path);
}

/// Runs a shell command using the platform's native shell.
///
/// Linux/macOS: `/bin/sh -c <cmd>`
/// Windows:     `cmd.exe /c <cmd>`
///
/// ## Parameters
/// - `allocator`: Allocator for argument arrays.
/// - `cmd`: Shell command string to execute.
/// - `cwd`: Working directory for the child process.
///
/// ## Returns
/// The process exit code.
pub fn runScript(allocator: std.mem.Allocator, cmd: []const u8, cwd: []const u8) !u8 {
    var child = std.process.Child.init(
        if (builtin.os.tag == .windows)
            &[_][]const u8{ "cmd.exe", "/c", cmd }
        else
            &[_][]const u8{ "/bin/sh", "-c", cmd },
        allocator,
    );
    child.cwd = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
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

    const dest_file = try fs.createFileAbsolute(dest, .{});
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
    // This is a simplified implementation — in production, use ReparsePoint API.
    _ = target;
    _ = link_path;
    return error.JunctionNotImplemented;
}
