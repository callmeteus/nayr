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

/// Computes a SHA256 hash over the lockfile, all package.json files, and the
/// sorted list of top-level packages currently present in node_modules.
///
/// Including the node_modules listing ensures that manually deleted packages
/// are detected even when package.json and the lockfile are unchanged.
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

    // Hash the sorted list of installed package names from node_modules.
    // This detects deleted packages without reading any file contents -
    // only directory entries (readdir) are accessed, which is very fast.
    try hashNodeModulesListing(allocator, &hasher, root_dir);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    // Encode as hex string.
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
}

/// Iterates the top-level node_modules directory and feeds the sorted list of
/// package names into `hasher`.  Scoped packages (@scope/pkg) are also expanded
/// one level deeper.  Also hashes the .bin/ directory so that missing bin stubs
/// are detected and trigger a full reinstall on the next `nayr install`.
fn hashNodeModulesListing(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    root_dir: []const u8,
) !void {
    const nm_path = try std.fs.path.join(allocator, &.{ root_dir, "node_modules" });
    defer allocator.free(nm_path);

    var nm_dir = std.fs.openDirAbsolute(nm_path, .{ .iterate = true }) catch return;
    defer nm_dir.close();

    var names = std.ArrayList([]const u8).init(allocator);
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit();
    }

    var it = nm_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.name[0] == '.') continue;
        if (entry.kind != .directory and entry.kind != .sym_link) continue;

        if (entry.name[0] == '@') {
            // Scoped scope directory: expand one level.
            const scope_path = try std.fs.path.join(allocator, &.{ nm_path, entry.name });
            defer allocator.free(scope_path);
            var scope_dir = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch continue;
            defer scope_dir.close();
            var sit = scope_dir.iterate();
            while (try sit.next()) |sub| {
                if (sub.kind != .directory and sub.kind != .sym_link) continue;
                try names.append(try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, sub.name }));
            }
            continue;
        }

        try names.append(try allocator.dupe(u8, entry.name));
    }

    // Sort for a deterministic hash regardless of filesystem ordering.
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (names.items) |name| {
        hasher.update(name);
        hasher.update("\n");
        // Hash nested node_modules for this package so missing version-specific
        // installs (e.g. parse5/node_modules/entities@6 when root has entities@2)
        // invalidate the integrity file and trigger a full link pass.
        try hashNestedNodeModulesListing(allocator, hasher, nm_path, name);
    }

    // Hash the .bin/ directory listing so that missing bin stubs (e.g. .bin/tsc)
    // are detected as a hash mismatch, causing the next `nayr install` to run the
    // full link phase instead of exiting early with "Already up to date".
    try hashBinListing(allocator, hasher, nm_path);
}

/// Hashes the sorted nested package names under `{nm_path}/{parent}/node_modules/`.
fn hashNestedNodeModulesListing(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    nm_path: []const u8,
    parent_name: []const u8,
) !void {
    const parent_nm = try std.fs.path.join(allocator, &.{ nm_path, parent_name, "node_modules" });
    defer allocator.free(parent_nm);

    var nested_dir = std.fs.openDirAbsolute(parent_nm, .{ .iterate = true }) catch return;
    defer nested_dir.close();

    var nested_names = std.ArrayList([]const u8).init(allocator);
    defer {
        for (nested_names.items) |n| allocator.free(n);
        nested_names.deinit();
    }

    var it = nested_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.name[0] == '.') continue;
        if (entry.kind != .directory and entry.kind != .sym_link) continue;

        if (entry.name[0] == '@') {
            const scope_path = try std.fs.path.join(allocator, &.{ parent_nm, entry.name });
            defer allocator.free(scope_path);
            var scope_dir = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch continue;
            defer scope_dir.close();
            var sit = scope_dir.iterate();
            while (try sit.next()) |sub| {
                if (sub.kind != .directory and sub.kind != .sym_link) continue;
                try nested_names.append(try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, sub.name }));
            }
            continue;
        }

        try nested_names.append(try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, nested_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (nested_names.items) |nested| {
        hasher.update(parent_name);
        hasher.update("/");
        hasher.update(nested);
        hasher.update("\n");
    }
}

/// Hashes the sorted list of entries in `node_modules/.bin/` into `hasher`.
fn hashBinListing(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    nm_path: []const u8,
) !void {
    const bin_path = try std.fs.path.join(allocator, &.{ nm_path, ".bin" });
    defer allocator.free(bin_path);

    var bin_dir = std.fs.openDirAbsolute(bin_path, .{ .iterate = true }) catch return;
    defer bin_dir.close();

    var bin_names = std.ArrayList([]const u8).init(allocator);
    defer {
        for (bin_names.items) |n| allocator.free(n);
        bin_names.deinit();
    }

    var bin_it = bin_dir.iterate();
    while (try bin_it.next()) |entry| {
        if (entry.name[0] == '.') continue;
        try bin_names.append(try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, bin_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (bin_names.items) |name| {
        hasher.update(".bin/");
        hasher.update(name);
        hasher.update("\n");
    }
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
