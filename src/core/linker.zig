//! node_modules Linker
//!
//! Creates the node_modules directory tree from the hoisted package layout
//! produced by the hoister. For each hoisted entry, the linker:
//!
//!   - Registry packages: hardlinks (or copies) files from the cache.
//!   - Workspace packages: creates a symlink → workspace directory.
//!   - Linked packages (nayr link): creates a symlink → linked directory.
//!   - Bin entries: creates stubs in `.bin/` for each executable.
//!
//! The linker also removes "extraneous" packages: directories in node_modules
//! that are not in the hoisted layout (e.g. from a previous install of a
//! now-removed dependency).

const std = @import("std");
const hoister = @import("hoister.zig");
const cache_mod = @import("cache.zig");
const platform = @import("../util/platform.zig");
const fs_util = @import("../util/fs.zig");
const output = @import("../util/output.zig");
const json_util = @import("../util/json.zig");
const HoistedPackage = hoister.HoistedPackage;
const Cache = cache_mod.Cache;

// ============================================================================
// Public API
// ============================================================================

/// Creates the full node_modules tree for the project.
///
/// ## Parameters
/// - `allocator`: All paths are allocated here.
/// - `root_dir`: Absolute path to the project root.
/// - `hoisted`: The hoisted package layout.
/// - `cache`: Global cache for resolving package contents.
/// - `workspace_paths`: Map of workspace package name → absolute path.
/// - `writer`: Output event sink.
pub fn link(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    hoisted: []const HoistedPackage,
    cache: *Cache,
    workspace_paths: *const std.StringHashMapUnmanaged([]const u8),
    writer: output.Writer,
) !void {
    const node_modules = try std.fs.path.join(allocator, &.{ root_dir, "node_modules" });
    defer allocator.free(node_modules);
    try fs_util.mkdirAllRecursive(allocator, node_modules);

    const bin_dir = try std.fs.path.join(allocator, &.{ node_modules, ".bin" });
    defer allocator.free(bin_dir);
    try fs_util.mkdirAllRecursive(allocator, bin_dir);

    // Track all installed package names so we can detect extraneous entries.
    var installed = std.StringHashMapUnmanaged(void){};
    defer installed.deinit(allocator);

    for (hoisted, 0..) |hp, i| {
        const dest = try std.fs.path.join(allocator, &.{ root_dir, hp.install_path });
        defer allocator.free(dest);

        try installed.put(allocator, hp.name, {});

        if (hp.pkg.is_workspace) {
            // Workspace / linked: symlink to the local directory.
            const ws_path = workspace_paths.get(hp.name) orelse continue;
            fs_util.mkdirParents(allocator, dest) catch {};
            std.fs.deleteTreeAbsolute(dest) catch {};
            platform.symlinkOrJunction(ws_path, dest) catch |err| {
                writer.emit(.{ .warning = @errorName(err) });
            };
            if (hp.pkg.is_linked) {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "linked: {s} → {s}",
                    .{ hp.name, ws_path },
                ) catch null;
                if (msg) |m| {
                    defer allocator.free(m);
                    writer.emit(.{ .info = m });
                }
            }
        } else {
            // Registry package: copy from cache.
            const cache_dir = cache.extractedDir(hp.pkg.registry, hp.name, hp.version) catch continue;
            defer allocator.free(cache_dir);

            try copyPackageDir(allocator, cache_dir, dest);

            // Create .bin/ stubs for this package's executables.
            try linkBinEntries(allocator, bin_dir, dest, hp.name);
        }

        writer.emit(.{ .link_progress = .{
            .linked = @intCast(i + 1),
            .total = @intCast(hoisted.len),
        } });
    }

    // Remove extraneous entries (packages present in node_modules but not
    // in the hoisted layout - they were removed from package.json).
    try removeExtraneous(allocator, node_modules, &installed, writer);
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Copies all files from `src_dir` into `dest_dir` using hardlinks where
/// possible (same filesystem) or copies otherwise.
fn copyPackageDir(allocator: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8) !void {
    std.fs.deleteTreeAbsolute(dest_dir) catch {};
    try fs_util.mkdirAllRecursive(allocator, dest_dir);

    var src = std.fs.openDirAbsolute(src_dir, .{ .iterate = true }) catch return;
    defer src.close();

    try copyDirRecursive(allocator, &src, src_dir, dest_dir);
}

fn copyDirRecursive(
    allocator: std.mem.Allocator,
    dir: *std.fs.Dir,
    src_base: []const u8,
    dest_base: []const u8,
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".integrity")) continue;

        const src_path = try std.fs.path.join(allocator, &.{ src_base, entry.name });
        defer allocator.free(src_path);
        const dest_path = try std.fs.path.join(allocator, &.{ dest_base, entry.name });
        defer allocator.free(dest_path);

        switch (entry.kind) {
            .directory => {
                try fs_util.mkdirAllRecursive(allocator, dest_path);
                var sub = std.fs.openDirAbsolute(src_path, .{ .iterate = true }) catch continue;
                defer sub.close();
                try copyDirRecursive(allocator, &sub, src_path, dest_path);
            },
            .file => {
                platform.hardlinkOrCopy(src_path, dest_path) catch {
                    platform.copyFile(src_path, dest_path) catch {};
                };
            },
            .sym_link => {
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = std.fs.readLinkAbsolute(src_path, &link_buf) catch continue;
                platform.symlinkOrJunction(target, dest_path) catch {};
            },
            else => {},
        }
    }
}

/// Creates .bin/ stubs for all executables declared in a package's package.json.
fn linkBinEntries(
    allocator: std.mem.Allocator,
    bin_dir: []const u8,
    pkg_dir: []const u8,
    pkg_name: []const u8,
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, "package.json" });
    defer allocator.free(manifest_path);

    var manifest = json_util.parseFile(allocator, manifest_path) catch return;
    defer manifest.deinit(allocator);

    switch (manifest.bin) {
        .none => {},
        .single => |script| {
            const script_path = try std.fs.path.join(allocator, &.{ pkg_dir, script });
            defer allocator.free(script_path);
            // Use the last path component of the package name as the binary name.
            const bin_name = if (std.mem.indexOfScalar(u8, pkg_name, '/')) |slash|
                pkg_name[slash + 1 ..]
            else
                pkg_name;
            platform.createBinStub(allocator, bin_dir, bin_name, script_path) catch {};
        },
        .map => |entries| {
            var it = entries.iterator();
            while (it.next()) |kv| {
                const script_path = try std.fs.path.join(allocator, &.{ pkg_dir, kv.value_ptr.* });
                defer allocator.free(script_path);
                platform.createBinStub(allocator, bin_dir, kv.key_ptr.*, script_path) catch {};
            }
        },
    }
}

/// Removes node_modules subdirectories not present in the installed set.
fn removeExtraneous(
    allocator: std.mem.Allocator,
    node_modules: []const u8,
    installed: *const std.StringHashMapUnmanaged(void),
    writer: output.Writer,
) !void {
    var dir = std.fs.openDirAbsolute(node_modules, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue; // keep .bin/, .cache/, etc.

        const pkg_name: []const u8 = entry.name;

        // Handle scoped packages: the entry is `@scope`, look inside.
        if (entry.name[0] == '@') {
            const scope_path = try std.fs.path.join(allocator, &.{ node_modules, entry.name });
            defer allocator.free(scope_path);
            var scope_dir = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch continue;
            defer scope_dir.close();
            var scope_iter = scope_dir.iterate();
            while (try scope_iter.next()) |sub| {
                const full_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, sub.name });
                defer allocator.free(full_name);
                if (!installed.contains(full_name)) {
                    const sub_path = try std.fs.path.join(allocator, &.{ scope_path, sub.name });
                    defer allocator.free(sub_path);
                    std.fs.deleteTreeAbsolute(sub_path) catch {};
                    const msg = try std.fmt.allocPrint(allocator, "removed extraneous: {s}", .{full_name});
                    defer allocator.free(msg);
                    writer.emit(.{ .info = msg });
                }
            }
            continue;
        }

        if (!installed.contains(pkg_name)) {
            const pkg_path = try std.fs.path.join(allocator, &.{ node_modules, entry.name });
            defer allocator.free(pkg_path);
            std.fs.deleteTreeAbsolute(pkg_path) catch {};
            const msg = try std.fmt.allocPrint(allocator, "removed extraneous: {s}", .{pkg_name});
            defer allocator.free(msg);
            writer.emit(.{ .info = msg });
        }
    }
}
