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
    // SAFETY: `rng` is fully initialized by `random.bytes` before any use.
    var rng: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&rng));
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(allocator, "{s}/nayr-{d}-{x}.tmp", .{ tmp_dir, pid, rng });
}

/// Generates a unique temporary directory path inside `tmp_dir`.
pub fn tempDirPath(allocator: std.mem.Allocator, tmp_dir: []const u8) ![]const u8 {
    // SAFETY: `rng` is fully initialized by `random.bytes` before any use.
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

    const now: u64 = @intCast(std.time.timestamp());
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full = try std.fs.path.join(allocator, &.{ tmp_dir, entry.name });
        defer allocator.free(full);

        const f = std.fs.openFileAbsolute(full, .{}) catch continue;
        const stat = f.stat() catch {
            f.close();
            continue;
        };
        f.close();
        const mtime_sec: u64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
        const age = now -| mtime_sec;
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
///   - `*`  - matches any sequence of characters within a single path segment
///   - `**` - matches any sequence of path segments (zero or more)
///   - `?`  - matches any single character
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
        // Never descend into node_modules - it is never a workspace source dir
        // and may contain thousands of packages, making the traversal extremely slow.
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        // Skip hidden directories (e.g. .git, .cache).
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        const entry_rel = if (rel.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel, entry.name });
        defer allocator.free(entry_rel);

        if (globMatch(pattern, entry_rel)) {
            try results.append(try std.fs.path.join(allocator, &.{ base_dir, entry_rel }));
        }

        // Only recurse into directories that could lead to a match.
        // For patterns without **, only recurse when the current entry
        // is a proper prefix of the pattern's directory part. This prevents
        // walking into sibling branches that can never yield a match.
        if (entry.kind == .directory and patternHasMoreSegments(pattern, entry_rel)) {
            // Without **, the current path must be a prefix of the pattern to recurse.
            if (std.mem.indexOf(u8, pattern, "**") == null) {
                // Build the directory prefix of the pattern up to the same depth.
                const depth = std.mem.count(u8, entry_rel, "/") + 1;
                var pat_prefix_end: usize = 0;
                var slashes_seen: usize = 0;
                for (pattern, 0..) |ch, i| {
                    if (ch == '/') {
                        slashes_seen += 1;
                        if (slashes_seen == depth) {
                            pat_prefix_end = i;
                            break;
                        }
                    }
                } else {
                    pat_prefix_end = pattern.len;
                }
                const pat_prefix = pattern[0..pat_prefix_end];
                // If the pattern prefix so far doesn't glob-match the current
                // relative path, no child of this dir can match - skip it.
                if (!globMatch(pat_prefix, entry_rel)) continue;
            }

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
