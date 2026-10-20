//! Per-package lifecycle cache
//!
//! Tracks which `node_modules` install paths already ran lifecycle scripts for a
//! given package identity (name, version, integrity / git source). When an entry
//! matches and the directory is still present, the linker skips re-copying from
//! the global cache and `scripts.runAll` skips native `install` / `postinstall`
//! work — the main cost on CI when only a few dependencies change.

const std = @import("std");
const hoister = @import("hoister.zig");
const HoistedPackage = hoister.HoistedPackage;

const state_file_name = ".nayr-lifecycle";
const state_header = "# nayr lifecycle v1\n";

/// In-memory map of install path → fingerprint hex (scripts completed).
pub const State = struct {
    completed: std.StringHashMapUnmanaged([]const u8),

    /// Loads `node_modules/.nayr-lifecycle` when present.
    ///
    /// ## Parameters
    /// - `allocator`: Owns returned strings and map keys/values.
    /// - `root_dir`: Project root.
    ///
    /// ## Returns
    /// An empty map when the state file is missing or unreadable.
    pub fn load(allocator: std.mem.Allocator, root_dir: []const u8) !State {
        var state = State{
            .completed = .{},
        };

        const path = try std.fs.path.join(allocator, &.{ root_dir, "node_modules", state_file_name });
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return state;
        defer file.close();
        const contents = file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return state;
        defer allocator.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] == '#') continue;

            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const install_path = line[0..tab];
            const fingerprint = line[tab + 1 ..];
            if (install_path.len == 0 or fingerprint.len == 0) continue;

            const path_key = try allocator.dupe(u8, install_path);
            const fp_val = try allocator.dupe(u8, fingerprint);
            const gop = try state.completed.getOrPut(allocator, path_key);
            if (gop.found_existing) {
                allocator.free(fp_val);
                allocator.free(path_key);
            } else {
                gop.value_ptr.* = fp_val;
            }
        }

        return state;
    }

    /// Writes the state file and drops entries not in `hoisted`.
    ///
    /// ## Parameters
    /// - `allocator`: Scratch allocator.
    /// - `root_dir`: Project root.
    /// - `hoisted`: Current install layout (used to prune stale paths).
    pub fn save(
        self: *State,
        allocator: std.mem.Allocator,
        root_dir: []const u8,
        hoisted: []const HoistedPackage,
    ) !void {
        var keep = std.StringHashMapUnmanaged(void){};
        defer keep.deinit(allocator);
        for (hoisted) |hp| {
            try keep.put(allocator, hp.install_path, {});
        }

        var keys = try allocator.alloc([]const u8, self.completed.count());
        defer allocator.free(keys);
        var ki: usize = 0;
        var it = self.completed.keyIterator();
        while (it.next()) |key| {
            keys[ki] = key.*;
            ki += 1;
        }

        for (keys[0..ki]) |key| {
            if (keep.get(key) == null) {
                const removed = self.completed.fetchRemove(key);
                if (removed) |entry| {
                    allocator.free(entry.key);
                    allocator.free(entry.value);
                }
            }
        }

        const nm_path = try std.fs.path.join(allocator, &.{ root_dir, "node_modules" });
        defer allocator.free(nm_path);
        try std.fs.createDirAbsolute(nm_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const path = try std.fs.path.join(allocator, &.{ nm_path, state_file_name });
        defer allocator.free(path);

        var body = std.ArrayList(u8).init(allocator);
        defer body.deinit();
        try body.appendSlice(state_header);

        var sorted_keys = try allocator.alloc([]const u8, self.completed.count());
        defer allocator.free(sorted_keys);
        var si: usize = 0;
        var it2 = self.completed.keyIterator();
        while (it2.next()) |key| {
            sorted_keys[si] = key.*;
            si += 1;
        }
        std.mem.sort([]const u8, sorted_keys[0..si], {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);

        for (sorted_keys[0..si]) |key| {
            const fp = self.completed.get(key) orelse continue;
            try body.writer().print("{s}\t{s}\n", .{ key, fp });
        }

        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(body.items);
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        var it = self.completed.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.completed.deinit(allocator);
    }

    /// Clears every cached entry (e.g. `nayr install --force`).
    pub fn clear(self: *State, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        self.completed = .{};
    }

    /// Returns true when lifecycle scripts already succeeded for this path and fingerprint.
    pub fn isComplete(self: *const State, install_path: []const u8, fingerprint: []const u8) bool {
        const stored = self.completed.get(install_path) orelse return false;
        return std.mem.eql(u8, stored, fingerprint);
    }

    /// Records a successful lifecycle run for an install path.
    pub fn markComplete(self: *State, allocator: std.mem.Allocator, install_path: []const u8, fingerprint: []const u8) !void {
        if (self.completed.getPtr(install_path)) |value_ptr| {
            if (std.mem.eql(u8, value_ptr.*, fingerprint)) {
                return;
            }
            allocator.free(value_ptr.*);
            value_ptr.* = try allocator.dupe(u8, fingerprint);
            return;
        }

        const path_key = try allocator.dupe(u8, install_path);
        const fp_val = try allocator.dupe(u8, fingerprint);
        try self.completed.put(allocator, path_key, fp_val);
    }

    /// Returns true when the package directory can be left untouched (skip cache copy).
    pub fn shouldSkipRelink(
        self: *const State,
        allocator: std.mem.Allocator,
        root_dir: []const u8,
        install_path: []const u8,
        fingerprint: []const u8,
    ) bool {
        if (!self.isComplete(install_path, fingerprint)) {
            return false;
        }

        const pkg_dir = std.fs.path.join(allocator, &.{ root_dir, install_path }) catch return false;
        defer allocator.free(pkg_dir);

        const manifest_path = std.fs.path.join(allocator, &.{ pkg_dir, "package.json" }) catch return false;
        defer allocator.free(manifest_path);

        std.fs.accessAbsolute(manifest_path, .{}) catch return false;
        return true;
    }

    /// Returns true when lifecycle scripts must run for this hoisted package.
    pub fn needsScripts(
        self: *const State,
        allocator: std.mem.Allocator,
        hp: HoistedPackage,
        force: bool,
    ) bool {
        if (force) {
            return true;
        }
        if (hp.pkg.is_workspace) {
            return false;
        }

        const fp = computeFingerprint(allocator, hp) catch return true;
        defer allocator.free(fp);

        return !self.isComplete(hp.install_path, fp);
    }
};

/// Computes a stable hex SHA-256 fingerprint for a hoisted package.
///
/// ## Parameters
/// - `allocator`: Owns the returned digest string.
/// - `hp`: Hoisted install entry.
///
/// ## Returns
/// Lowercase hex digest owned by the caller.
pub fn computeFingerprint(allocator: std.mem.Allocator, hp: HoistedPackage) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(hp.name);
    hasher.update("\n");
    hasher.update(hp.version);
    hasher.update("\n");
    hasher.update(hp.pkg.integrity);
    hasher.update("\n");
    hasher.update(hp.pkg.tarball_url);
    hasher.update("\n");
    if (hp.pkg.is_git) {
        hasher.update("git\n");
    } else if (hp.pkg.is_linked) {
        hasher.update("link\n");
    } else if (hp.pkg.is_workspace) {
        hasher.update("workspace\n");
    } else {
        hasher.update("registry\n");
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
}
