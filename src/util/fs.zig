//! Filesystem Utilities
//!
//! Helper functions for common filesystem operations used across nayr:
//! directory traversal, glob matching, atomic temp-file management, and
//! safe directory creation.

const std = @import("std");

// ============================================================================
// Safe directory creation
// ============================================================================

/// Creates a directory and all intermediate parents, ignoring the error if
/// it already exists.
///
/// ## Parameters
/// - `path`: Absolute path to create.
pub fn mkdirAll(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

/// Creates all parent directories of a file path, if they do not exist.
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `file_path`: Absolute path to a file whose parent dirs should exist.
pub fn mkdirParents(allocator: std.mem.Allocator, file_path: []const u8) !void {
    const dir = std.fs.path.dirname(file_path) orelse return;
    try mkdirAllRecursive(allocator, dir);
}

/// Recursively creates a directory and all parents.
pub fn mkdirAllRecursive(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    // std.fs.makeDirAbsolute walks up to root automatically on recent Zig.
    std.fs.cwd().makePath(path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

// ============================================================================
// Temp file management
// ============================================================================

/// Generates a unique temporary file path inside `tmp_dir`.
///
/// The file name is `nayr-<pid>-<random>.tmp`. Uses `std.crypto.random` for
/// the random component to avoid collisions between concurrent processes.
///
/// ## Parameters
/// - `allocator`: For the result string.
/// - `tmp_dir`: Directory where the temp file should live.
///
/// ## Returns
/// Caller owns the returned slice.
pub fn tempPath(allocator: std.mem.Allocator, tmp_dir: []const u8) ![]const u8 {
    var rng: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&rng));
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(allocator, "{s}/nayr-{d}-{x}.tmp", .{ tmp_dir, pid, rng });
}

/// Generates a unique temporary directory path inside `tmp_dir`.
pub fn tempDirPath(allocator: std.mem.Allocator, tmp_dir: []const u8) ![]const u8 {
    var rng: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&rng));
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(allocator, "{s}/nayr-{d}-{x}.tmpdir", .{ tmp_dir, pid, rng });
}

/// Removes all entries in `tmp_dir` whose modification time is older than
/// `max_age_secs`. Called at startup to clean up after crashed processes.
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `tmp_dir`: The `.tmp/` directory path.
/// - `max_age_secs`: Files older than this many seconds are removed.
pub fn cleanStaleTempFiles(allocator: std.mem.Allocator, tmp_dir: []const u8, max_age_secs: u64) !void {
    var dir = std.fs.openDirAbsolute(tmp_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    const now = @as(u64, @intCast(std.time.timestamp()));
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full = try std.fs.path.join(allocator, &.{ tmp_dir, entry.name });
        defer allocator.free(full);

        const f = std.fs.openFileAbsolute(full, .{}) catch continue;
        const stat = f.stat() catch { f.close(); continue; };
        f.close();
        const age = now -| @as(u64, @intCast(@divTrunc(stat.mtime, std.time.ns_per_s)));
        if (age > max_age_secs) {
            std.fs.deleteTreeAbsolute(full) catch {};
        }
    }
}

// ============================================================================
// Glob matching
// ============================================================================

/// Returns true when `path` matches the given glob `pattern`.
///
/// Supports:
///   - `*`  — matches any sequence of characters within a single path segment
///   - `**` — matches any sequence of path segments (zero or more)
///   - `?`  — matches any single character
///
/// ## Parameters
/// - `pattern`: Glob pattern (e.g. "packages/*", "**\/node_modules\/**").
/// - `path`: The path to test against the pattern.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globMatchInner(pattern, path);
}

/// Expands a glob pattern against a base directory and returns all matching
/// paths (relative to `base_dir`).
///
/// ## Parameters
/// - `allocator`: Allocator for the result slice and each path string.
/// - `base_dir`: The directory to search from.
/// - `pattern`: Glob pattern (e.g. "packages/*").
///
/// ## Returns
/// Slice of matching paths. Caller owns each string and the slice.
pub fn globExpand(allocator: std.mem.Allocator, base_dir: []const u8, pattern: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8).init(allocator);

    var dir = std.fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch return results.toOwnedSlice();
    defer dir.close();

    try walkGlob(allocator, &dir, base_dir, "", pattern, &results);
    return results.toOwnedSlice();
}

// ============================================================================
// Internal glob helpers
// ============================================================================

fn walkGlob(
    allocator: std.mem.Allocator,
    dir: *std.fs.Dir,
    base_dir: []const u8,
    rel: []const u8, // current relative path from base
    pattern: []const u8,
    results: *std.ArrayList([]const u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const entry_rel = if (rel.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel, entry.name });
        defer allocator.free(entry_rel);

        if (globMatch(pattern, entry_rel)) {
            try results.append(try std.fs.path.join(allocator, &.{ base_dir, entry_rel }));
        }

        // Recurse into subdirectories when the pattern has further segments.
        if (entry.kind == .directory and patternHasMoreSegments(pattern, entry_rel)) {
            const sub_path = try std.fs.path.join(allocator, &.{ base_dir, entry_rel });
            defer allocator.free(sub_path);
            var sub_dir = std.fs.openDirAbsolute(sub_path, .{ .iterate = true }) catch continue;
            defer sub_dir.close();
            try walkGlob(allocator, &sub_dir, base_dir, entry_rel, pattern, results);
        }
    }
}

/// Simple recursive glob matcher.
fn globMatchInner(pattern: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;

    while (pi < pattern.len and si < str.len) {
        if (pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*') {
            // `**` matches zero or more path segments.
            if (pi + 2 >= pattern.len) return true; // trailing **
            const rest_pat = pattern[pi + 2 ..];
            // Try matching from every position in str.
            var i = si;
            while (i <= str.len) : (i += 1) {
                if (globMatchInner(rest_pat, str[i..])) return true;
            }
            return false;
        } else if (pattern[pi] == '*') {
            // `*` matches within a single segment (no `/`).
            if (pi + 1 >= pattern.len) {
                // Trailing *: match remainder if no slash.
                return std.mem.indexOfScalar(u8, str[si..], '/') == null;
            }
            const rest_pat = pattern[pi + 1 ..];
            var i = si;
            while (i <= str.len) : (i += 1) {
                if (i > si and str[i - 1] == '/') break; // don't cross /
                if (globMatchInner(rest_pat, str[i..])) return true;
            }
            return false;
        } else if (pattern[pi] == '?') {
            if (str[si] == '/') return false;
            pi += 1;
            si += 1;
        } else if (pattern[pi] == str[si]) {
            pi += 1;
            si += 1;
        } else {
            return false;
        }
    }

    // Consume any trailing `*` patterns.
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;

    return pi == pattern.len and si == str.len;
}

/// Returns true if the pattern has more path segments than the current entry.
fn patternHasMoreSegments(pattern: []const u8, current: []const u8) bool {
    const slash_count_pat = std.mem.count(u8, pattern, "/");
    const slash_count_cur = std.mem.count(u8, current, "/");
    return slash_count_pat > slash_count_cur or std.mem.indexOf(u8, pattern, "**") != null;
}
