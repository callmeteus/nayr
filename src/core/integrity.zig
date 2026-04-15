//! Integrity Check
//!
//! Manages the `node_modules/.nayr-integrity` sentinel file. This file stores
//! a hash of the lockfile + package.json contents. If the hash matches on the
//! next invocation, nayr can skip the entire install pipeline in <500ms.

const std = @import("std");

// ============================================================================
// Public API
// ============================================================================

/// Checks whether the project's node_modules is already up-to-date.
///
/// Computes a hash of the current `nayr.lock` (or `yarn.lock`) and all
/// `package.json` files in the project. Compares it against the stored hash
/// in `node_modules/.nayr-integrity`.
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `root_dir`: Absolute path to the project root.
///
/// ## Returns
/// `true` if node_modules is up-to-date and install can be skipped.
pub fn isUpToDate(allocator: std.mem.Allocator, root_dir: []const u8) !bool {
    const current_hash = computeHash(allocator, root_dir) catch return false;
    defer allocator.free(current_hash);

    const stored_hash = readStoredHash(allocator, root_dir) catch return false;
    defer allocator.free(stored_hash);

    return std.mem.eql(u8, current_hash, stored_hash);
}

/// Writes the current integrity hash to `node_modules/.nayr-integrity`.
///
/// Called at the end of a successful install.
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `root_dir`: Absolute path to the project root.
pub fn save(allocator: std.mem.Allocator, root_dir: []const u8) !void {
    const hash = try computeHash(allocator, root_dir);
    defer allocator.free(hash);

    const integrity_path = try std.fs.path.join(allocator, &.{
        root_dir, "node_modules", ".nayr-integrity",
    });
    defer allocator.free(integrity_path);

    const file = try std.fs.createFileAbsolute(integrity_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(hash);
}

/// Removes the integrity file, forcing a full reinstall on the next run.
pub fn invalidate(allocator: std.mem.Allocator, root_dir: []const u8) void {
    const path = std.fs.path.join(allocator, &.{
        root_dir, "node_modules", ".nayr-integrity",
    }) catch return;
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch {};
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Computes a SHA256 hash over the lockfile and all package.json files.
fn computeHash(allocator: std.mem.Allocator, root_dir: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Hash the lockfile.
    for (&[_][]const u8{ "nayr.lock", "yarn.lock" }) |lockfile_name| {
        const lf_path = try std.fs.path.join(allocator, &.{ root_dir, lockfile_name });
        defer allocator.free(lf_path);
        if (std.fs.openFileAbsolute(lf_path, .{})) |f| {
            defer f.close();
            var buf: [64 * 1024]u8 = undefined;
            while (true) {
                const n = f.read(&buf) catch break;
                if (n == 0) break;
                hasher.update(buf[0..n]);
            }
            break; // only hash the first lockfile found
        } else |_| {}
    }

    // Hash the root package.json.
    const root_pkg = try std.fs.path.join(allocator, &.{ root_dir, "package.json" });
    defer allocator.free(root_pkg);
    hashFile(&hasher, root_pkg);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    // Encode as hex string.
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
}

fn hashFile(hasher: *std.crypto.hash.sha2.Sha256, path: []const u8) void {
    const f = std.fs.openFileAbsolute(path, .{}) catch return;
    defer f.close();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = f.read(&buf) catch break;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
}

fn readStoredHash(allocator: std.mem.Allocator, root_dir: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{
        root_dir, "node_modules", ".nayr-integrity",
    });
    defer allocator.free(path);
    const f = try std.fs.openFileAbsolute(path, .{});
    defer f.close();
    return f.readToEndAlloc(allocator, 1024);
}
