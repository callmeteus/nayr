//! Global Package Cache
//!
//! The cache stores downloaded tarballs and extracted package contents under
//! `~/.nayr/cache/<registry-host>/<name>/<version>/`. All cache operations
//! are 100% lock-free: no mutexes, no file locks, no flock(2) calls.
//!
//! Lock-free safety is achieved through atomic filesystem operations:
//!
//!   1. Download goes to a temp file: `~/.nayr/cache/.tmp/<random>`
//!   2. Extraction goes to a temp dir: `~/.nayr/cache/.tmp/<random-dir>/`
//!   3. On completion, an atomic `rename()` moves to the final path.
//!   4. Rename is atomic on POSIX (NTFS: MoveFileExW with REPLACE_EXISTING).
//!   5. Two concurrent processes downloading the same version both rename
//!      successfully - the second overwrites the first with identical content
//!      (deterministic for the same tarball). No data corruption possible.
//!
//! Readers check for directory existence with a simple stat() call. If the
//! directory exists, it is complete (rename is atomic). If it does not, they
//! trigger a download. The window where two threads/processes both decide to
//! download the same package is harmless (idempotent writes).

const std = @import("std");
const platform = @import("../util/platform.zig");
const fs_util = @import("../util/fs.zig");

// ============================================================================
// Cache
// ============================================================================

/// The global nayr package cache.
pub const Cache = struct {
    /// Root directory of the cache (e.g. `~/.nayr/cache`).
    root: []const u8,
    allocator: std.mem.Allocator,

    // -------------------------------------------------------------------------
    // Init / deinit
    // -------------------------------------------------------------------------

    /// Opens (or initialises) the cache at the given root directory.
    ///
    /// Creates the directory tree if it does not exist. Also removes stale
    /// temp files left by crashed processes.
    ///
    /// ## Parameters
    /// - `allocator`: Owns the `root` string and scratch allocations.
    /// - `root`: Absolute path to the cache root.
    pub fn init(allocator: std.mem.Allocator, root: []const u8) !Cache {
        const root_dup = try allocator.dupe(u8, root);

        // Ensure the cache and temp directories exist.
        try fs_util.mkdirAllRecursive(allocator, root_dup);
        const tmp_dir = try std.fs.path.join(allocator, &.{ root_dup, ".tmp" });
        defer allocator.free(tmp_dir);
        try fs_util.mkdirAllRecursive(allocator, tmp_dir);

        // Clean up stale temp files from previous crashed nayr processes.
        // Files older than 1 hour are safe to remove.
        fs_util.cleanStaleTempFiles(allocator, tmp_dir, 3600) catch {};

        return Cache{ .root = root_dup, .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.root);
    }

    // -------------------------------------------------------------------------
    // Cache queries
    // -------------------------------------------------------------------------

    /// Returns the cache directory path for the given package version.
    ///
    /// Path format: `<root>/<registry-host>/<name>/<version>/`
    ///
    /// ## Parameters
    /// - `registry_url`: Registry base URL (used to derive the host segment).
    /// - `name`: Package name (e.g. `"lodash"` or `"@babel/core"`).
    /// - `version`: Exact version string (e.g. `"4.17.21"`).
    ///
    /// ## Returns
    /// Absolute path string. Caller must free.
    pub fn packageDir(
        self: *const Cache,
        registry_url: []const u8,
        name: []const u8,
        version: []const u8,
    ) ![]const u8 {
        const host = registryHost(registry_url);
        // Sanitise the package name: replace `/` with `__` for filesystem safety.
        const safe_name = try std.mem.replaceOwned(u8, self.allocator, name, "/", "__");
        defer self.allocator.free(safe_name);
        return std.fs.path.join(self.allocator, &.{ self.root, host, safe_name, version });
    }

    /// Returns true when the given package version is already in cache and
    /// its integrity file is present.
    ///
    /// A missing integrity file means the package was partially extracted -
    /// treat as a cache miss so it gets re-downloaded.
    pub fn has(
        self: *const Cache,
        registry_url: []const u8,
        name: []const u8,
        version: []const u8,
    ) !bool {
        const dir = try self.packageDir(registry_url, name, version);
        defer self.allocator.free(dir);

        // The integrity sentinel file is written last during extraction,
        // so its presence means the directory is fully populated.
        const sentinel = try std.fs.path.join(self.allocator, &.{ dir, ".integrity" });
        defer self.allocator.free(sentinel);

        std.fs.accessAbsolute(sentinel, .{}) catch return false;
        return true;
    }

    /// Returns the path to the extracted tarball contents directory.
    ///
    /// The directory contains the package files as they should appear in
    /// `node_modules/<name>/` (i.e. the `package/` prefix is stripped).
    pub fn extractedDir(
        self: *const Cache,
        registry_url: []const u8,
        name: []const u8,
        version: []const u8,
    ) ![]const u8 {
        return self.packageDir(registry_url, name, version);
    }

    // -------------------------------------------------------------------------
    // Cache writes (lock-free)
    // -------------------------------------------------------------------------

    /// Stores a downloaded tarball in the cache.
    ///
    /// The tarball is first extracted to a temp directory, then atomically
    /// renamed to its final location. This function is safe to call from
    /// multiple threads/processes concurrently for the same package.
    ///
    /// ## Parameters
    /// - `registry_url`: Registry base URL.
    /// - `name`: Package name.
    /// - `version`: Exact version.
    /// - `tarball_data`: Raw `.tgz` bytes.
    pub fn store(
        self: *Cache,
        registry_url: []const u8,
        name: []const u8,
        version: []const u8,
        tarball_data: []const u8,
    ) !void {
        const final_dir = try self.packageDir(registry_url, name, version);
        defer self.allocator.free(final_dir);

        // If the final directory already exists (another process beat us),
        // we can skip the extraction entirely.
        const sentinel = try std.fs.path.join(self.allocator, &.{ final_dir, ".integrity" });
        defer self.allocator.free(sentinel);
        if ((std.fs.accessAbsolute(sentinel, .{}) catch null) != null) return;

        // Extract to a temp directory first.
        const tmp_dir_path = try fs_util.tempDirPath(self.allocator, try std.fs.path.join(self.allocator, &.{ self.root, ".tmp" }));
        defer self.allocator.free(tmp_dir_path);
        try fs_util.mkdirAllRecursive(self.allocator, tmp_dir_path);

        try extractTarball(self.allocator, tarball_data, tmp_dir_path);

        // Write the integrity sentinel last.
        const tmp_sentinel = try std.fs.path.join(self.allocator, &.{ tmp_dir_path, ".integrity" });
        defer self.allocator.free(tmp_sentinel);
        {
            const f = try std.fs.createFileAbsolute(tmp_sentinel, .{});
            defer f.close();
            try f.writeAll("ok");
        }

        // Ensure parent directories of the final path exist.
        try fs_util.mkdirParents(self.allocator, final_dir);

        // Atomic rename: this is the only write to the final location.
        // If another process already placed a complete directory here,
        // we overwrite it - both have identical contents (deterministic).
        platform.atomicRename(tmp_dir_path, final_dir) catch |err| {
            // PathAlreadyExists can occur on some platforms if rename cannot
            // replace a non-empty directory. In that case we just clean up
            // the temp directory and proceed (the cache already has the data).
            if (err == error.PathAlreadyExists) {
                std.fs.deleteTreeAbsolute(tmp_dir_path) catch {};
                return;
            }
            return err;
        };
    }

    // -------------------------------------------------------------------------
    // Cache management
    // -------------------------------------------------------------------------

    /// Lists all cached packages as `<name>@<version>` strings.
    ///
    /// Returns a slice of allocated strings. Caller owns each string and slice.
    pub fn list(self: *const Cache) ![][]const u8 {
        var results = std.ArrayList([]const u8).init(self.allocator);

        var root_dir = std.fs.openDirAbsolute(self.root, .{ .iterate = true }) catch return results.toOwnedSlice();
        defer root_dir.close();

        // Walk: root/<host>/<name>/<version>
        var host_iter = root_dir.iterate();
        while (try host_iter.next()) |host_entry| {
            if (host_entry.kind != .directory or host_entry.name[0] == '.') continue;
            const host_path = try std.fs.path.join(self.allocator, &.{ self.root, host_entry.name });
            defer self.allocator.free(host_path);

            var host_dir = std.fs.openDirAbsolute(host_path, .{ .iterate = true }) catch continue;
            defer host_dir.close();

            var name_iter = host_dir.iterate();
            while (try name_iter.next()) |name_entry| {
                if (name_entry.kind != .directory or name_entry.name[0] == '.') continue;
                const name_path = try std.fs.path.join(self.allocator, &.{ host_path, name_entry.name });
                defer self.allocator.free(name_path);

                var ver_dir = std.fs.openDirAbsolute(name_path, .{ .iterate = true }) catch continue;
                defer ver_dir.close();

                var ver_iter = ver_dir.iterate();
                while (try ver_iter.next()) |ver_entry| {
                    if (ver_entry.kind != .directory) continue;
                    const entry = try std.fmt.allocPrint(self.allocator, "{s}@{s}", .{
                        // Restore `/` in scoped package names.
                        try std.mem.replaceOwned(u8, self.allocator, name_entry.name, "__", "/"),
                        ver_entry.name,
                    });
                    try results.append(entry);
                }
            }
        }

        return results.toOwnedSlice();
    }

    /// Removes all entries from the cache. Safe even if other nayr processes
    /// are currently reading from it (POSIX semantics: open file descriptors
    /// keep the data alive until closed).
    pub fn clean(self: *Cache) !void {
        var root_dir = std.fs.openDirAbsolute(self.root, .{ .iterate = true }) catch return;
        defer root_dir.close();

        var iter = root_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.name[0] == '.') continue; // keep .tmp/
            const full = try std.fs.path.join(self.allocator, &.{ self.root, entry.name });
            defer self.allocator.free(full);
            std.fs.deleteTreeAbsolute(full) catch {};
        }
    }
};

// ============================================================================
// Tarball extraction
// ============================================================================

/// Extracts a `.tgz` tarball into `dest_dir`.
///
/// npm tarballs contain a `package/` root directory prefix. nayr strips
/// this prefix so that `dest_dir` directly contains the package files
/// (equivalent to what ends up in `node_modules/<name>/`).
fn extractTarball(allocator: std.mem.Allocator, data: []const u8, dest_dir: []const u8) !void {
    // Decompress gzip envelope.
    var fbs = std.io.fixedBufferStream(data);
    var decomp = std.compress.gzip.decompressor(fbs.reader());

    // Iterate tar entries.
    var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tar_iter = std.tar.iterator(decomp.reader(), .{
        .file_name_buffer = &file_name_buf,
        .link_name_buffer = &link_name_buf,
    });
    while (try tar_iter.next()) |entry| {
        // Strip the leading `package/` prefix that npm uses in tarballs.
        var path = entry.name;
        if (std.mem.startsWith(u8, path, "package/")) path = path["package/".len..];
        if (std.mem.startsWith(u8, path, "./")) path = path[2..];
        if (path.len == 0) continue;

        const dest = try std.fs.path.join(allocator, &.{ dest_dir, path });
        defer allocator.free(dest);

        switch (entry.kind) {
            .directory => try fs_util.mkdirAllRecursive(allocator, dest),
            .file => {
                try fs_util.mkdirParents(allocator, dest);
                const file = try std.fs.createFileAbsolute(dest, .{ .truncate = true });
                defer file.close();
                try entry.writeAll(file.writer());
            },
            .sym_link => {
                platform.symlinkOrJunction(entry.link_name, dest) catch {};
            },
        }
    }
}

// ============================================================================
// Helpers
// ============================================================================

/// Extracts the host portion of a registry URL for use as a cache segment.
///
/// Strips scheme and trailing slashes:
///   `https://registry.npmjs.org` → `registry.npmjs.org`
///   `http://npm.arpa`            → `npm.arpa`
fn registryHost(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "https://")) rest = rest[8..];
    if (std.mem.startsWith(u8, rest, "http://")) rest = rest[7..];
    rest = std.mem.trimRight(u8, rest, "/");
    return rest;
}
