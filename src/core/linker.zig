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
                const wmsg = std.fmt.allocPrint(
                    allocator,
                    "could not symlink {s} → {s}: {s}",
                    .{ hp.name, ws_path, @errorName(err) },
                ) catch null;
                if (wmsg) |m| {
                    defer allocator.free(m);
                    writer.emit(.{ .warning = m });
                }
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
            // Link bin stubs even for workspace/linked packages so that any
            // executables declared in their package.json#bin are available.
            try linkBinEntries(allocator, bin_dir, dest, hp.name, writer);
        } else if (hp.pkg.is_git) {
            // Git dependency: clone the repository directly into node_modules.
            // We preserve existing clones to avoid re-cloning on every install
            // (the integrity check guards re-entry at a higher level).
            try installGitPackage(allocator, hp.pkg.tarball_url, dest, hp.name, writer);
            try linkBinEntries(allocator, bin_dir, dest, hp.name, writer);
        } else {
            // Registry package: copy from cache.
            const cache_dir = cache.extractedDir(hp.pkg.registry, hp.name, hp.version) catch continue;
            defer allocator.free(cache_dir);

            copyPackageDir(allocator, cache_dir, dest) catch |err| {
                // Cache miss or I/O error: warn and skip. The dest directory was
                // already cleaned up by copyPackageDir so no empty dir is left.
                // The next `nayr install` will re-fetch the missing package.
                const wmsg = std.fmt.allocPrint(
                    allocator,
                    "cache miss for {s}@{s} ({s}) - will re-fetch on next install",
                    .{ hp.name, hp.version, @errorName(err) },
                ) catch null;
                if (wmsg) |m| {
                    defer allocator.free(m);
                    writer.emit(.{ .warning = m });
                }
                continue;
            };

            // Create .bin/ stubs for this package's executables.
            try linkBinEntries(allocator, bin_dir, dest, hp.name, writer);
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
// Bin stub repair
// ============================================================================

/// Walks `node_modules/` and creates any missing `.bin/` stubs.
///
/// This is a lightweight, idempotent pass that runs before the integrity
/// fast-path on every `nayr install`. It ensures bin stubs always exist for
/// every installed package, even when a previous install was interrupted,
/// the integrity file was stale, or `.bin/` was manually cleaned.
///
/// Only root-level packages are processed; nested `node_modules` (inside
/// package directories) are not touched - matching Yarn Classic behaviour.
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `root_dir`: Absolute path to the project root.
/// - `writer`: Output event sink (warnings only; no info emitted on success).
pub fn repairBinStubs(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    writer: output.Writer,
) !void {
    const node_modules = try std.fs.path.join(allocator, &.{ root_dir, "node_modules" });
    defer allocator.free(node_modules);

    var nm_dir = std.fs.openDirAbsolute(node_modules, .{ .iterate = true }) catch return;
    defer nm_dir.close();

    const bin_dir = try std.fs.path.join(allocator, &.{ node_modules, ".bin" });
    defer allocator.free(bin_dir);
    try fs_util.mkdirAllRecursive(allocator, bin_dir);

    var iter = nm_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue;

        if (entry.name[0] == '@') {
            // Scoped package: one level deeper.
            const scope_path = try std.fs.path.join(allocator, &.{ node_modules, entry.name });
            defer allocator.free(scope_path);
            var scope_dir = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch continue;
            defer scope_dir.close();
            var sit = scope_dir.iterate();
            while (try sit.next()) |sub| {
                if (sub.name[0] == '.') continue;
                const pkg_dir = try std.fs.path.join(allocator, &.{ scope_path, sub.name });
                defer allocator.free(pkg_dir);
                const pkg_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, sub.name });
                defer allocator.free(pkg_name);
                try linkBinEntries(allocator, bin_dir, pkg_dir, pkg_name, writer);
            }
            continue;
        }

        const pkg_dir = try std.fs.path.join(allocator, &.{ node_modules, entry.name });
        defer allocator.free(pkg_dir);
        try linkBinEntries(allocator, bin_dir, pkg_dir, entry.name, writer);
    }
}

// ============================================================================
// Broken package repair
// ============================================================================

/// Removes empty or incomplete package directories from `node_modules/`.
///
/// A package directory is considered broken when it contains no `package.json`.
/// This can happen when a previous install was interrupted after the directory
/// was created but before its tarball was extracted, leaving an empty stub that
/// fools the integrity check into thinking the package is present.
///
/// This pass runs before the integrity fast-path, so the missing directory
/// will cause a hash mismatch → full reinstall on the next check.
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `root_dir`: Absolute path to the project root.
/// - `writer`: Output event sink (warnings only).
pub fn repairBrokenPackages(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    writer: output.Writer,
) !void {
    const node_modules = try std.fs.path.join(allocator, &.{ root_dir, "node_modules" });
    defer allocator.free(node_modules);

    var nm_dir = std.fs.openDirAbsolute(node_modules, .{ .iterate = true }) catch return;
    defer nm_dir.close();

    var iter = nm_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue;

        if (entry.name[0] == '@') {
            // Scoped package scope directory: check each package inside.
            const scope_path = try std.fs.path.join(allocator, &.{ node_modules, entry.name });
            defer allocator.free(scope_path);
            var scope_dir = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch continue;
            defer scope_dir.close();
            var sit = scope_dir.iterate();
            while (try sit.next()) |sub| {
                if (sub.name[0] == '.') continue;
                const pkg_dir = try std.fs.path.join(allocator, &.{ scope_path, sub.name });
                defer allocator.free(pkg_dir);
                // Skip symlinks (linked packages).
                if (sub.kind == .sym_link) continue;
                const manifest = try std.fs.path.join(allocator, &.{ pkg_dir, "package.json" });
                defer allocator.free(manifest);
                if ((std.fs.accessAbsolute(manifest, .{}) catch null) == null) {
                    const full_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, sub.name });
                    defer allocator.free(full_name);
                    const wmsg = std.fmt.allocPrint(
                        allocator,
                        "warn: removing broken package dir: {s}",
                        .{full_name},
                    ) catch null;
                    if (wmsg) |m| {
                        defer allocator.free(m);
                        writer.emit(.{ .warning = m });
                    }
                    std.fs.deleteTreeAbsolute(pkg_dir) catch {};
                }
            }
            continue;
        }

        const pkg_dir = try std.fs.path.join(allocator, &.{ node_modules, entry.name });
        defer allocator.free(pkg_dir);
        // Skip symlinks (linked packages).
        if (entry.kind == .sym_link) continue;
        const manifest = try std.fs.path.join(allocator, &.{ pkg_dir, "package.json" });
        defer allocator.free(manifest);
        if ((std.fs.accessAbsolute(manifest, .{}) catch null) == null) {
            const wmsg = std.fmt.allocPrint(
                allocator,
                "warn: removing broken package dir: {s}",
                .{entry.name},
            ) catch null;
            if (wmsg) |m| {
                defer allocator.free(m);
                writer.emit(.{ .warning = m });
            }
            std.fs.deleteTreeAbsolute(pkg_dir) catch {};
        }
    }
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Installs a git dependency by cloning the repository into `dest`.
///
/// Preserves an existing clone to avoid re-cloning on every install run.
/// The presence of a `.git` subdirectory is used as the "already installed"
/// sentinel - consistent with how `git clone` leaves the directory.
///
/// On failure (git not in PATH, network error, etc.) a warning is emitted
/// and the function returns without error so the rest of the install continues.
fn installGitPackage(
    allocator: std.mem.Allocator,
    raw_url: []const u8,
    dest: []const u8,
    name: []const u8,
    writer: output.Writer,
) !void {
    const resolver = @import("../core/resolver.zig");
    const parts = resolver.parseGitDepUrl(raw_url);

    // When no subdir is involved the clone lands directly in `dest` and we
    // detect re-use via `.git/`.  With a subdir we clone to a temp path and
    // copy only the subdirectory, so we use `dest/package.json` as the marker.
    const already_installed = if (parts.subdir == null) blk: {
        const git_marker = try std.fs.path.join(allocator, &.{ dest, ".git" });
        defer allocator.free(git_marker);
        std.fs.accessAbsolute(git_marker, .{}) catch break :blk false;
        break :blk true;
    } else blk: {
        const pkg_marker = try std.fs.path.join(allocator, &.{ dest, "package.json" });
        defer allocator.free(pkg_marker);
        std.fs.accessAbsolute(pkg_marker, .{}) catch break :blk false;
        break :blk true;
    };
    if (already_installed) return;

    // Decide the clone target:
    //   no subdir → clone directly into dest
    //   subdir    → clone into a temp dir, then copy the subdir into dest
    const clone_dest = if (parts.subdir != null) blk: {
        // Use a unique temp path derived from dest to avoid conflicts between
        // concurrent installs of different packages.
        const tmp_dir = try platform.getTempDir(allocator);
        defer allocator.free(tmp_dir);
        break :blk try std.fmt.allocPrint(allocator, "{s}{c}nayr-git-{x}", .{
            tmp_dir, std.fs.path.sep, std.hash.Wyhash.hash(0, dest),
        });
    } else dest;
    defer if (parts.subdir != null) allocator.free(clone_dest);

    // Remove any partial previous clone before starting fresh.
    std.fs.deleteTreeAbsolute(clone_dest) catch {};
    fs_util.mkdirParents(allocator, clone_dest) catch {};

    const msg = if (parts.branch) |b|
        try std.fmt.allocPrint(allocator, "cloning git dep: {s}  ({s})", .{ name, b })
    else
        try std.fmt.allocPrint(allocator, "cloning git dep: {s}", .{name});
    defer allocator.free(msg);
    writer.emit(.{ .info = msg });

    // Build the git clone command.
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "git", "clone", "--depth", "1", "--quiet" });
    if (parts.branch) |b| try argv.appendSlice(&.{ "--branch", b });
    try argv.appendSlice(&.{ parts.clean_url, clone_dest });

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        std.fs.deleteTreeAbsolute(clone_dest) catch {};
        const wmsg = try std.fmt.allocPrint(allocator, "git clone failed for {s}: {s}", .{ name, @errorName(err) });
        defer allocator.free(wmsg);
        writer.emit(.{ .warning = wmsg });
        return;
    };

    const stderr_output = child.stderr.?.reader().readAllAlloc(allocator, 8 * 1024) catch "";
    defer if (stderr_output.len > 0) allocator.free(stderr_output);

    const result = child.wait() catch {
        std.fs.deleteTreeAbsolute(clone_dest) catch {};
        return;
    };
    const exit_code: u8 = switch (result) {
        .Exited => |c| c,
        else => 1,
    };

    if (exit_code != 0) {
        std.fs.deleteTreeAbsolute(clone_dest) catch {};
        const wmsg = try std.fmt.allocPrint(
            allocator,
            "git clone exited {d} for {s}{s}{s}",
            .{ exit_code, name, if (stderr_output.len > 0) ": " else "", std.mem.trimRight(u8, stderr_output, "\n") },
        );
        defer allocator.free(wmsg);
        writer.emit(.{ .warning = wmsg });
        return;
    }

    // If a subdirectory was requested, copy it to dest and remove the full clone.
    if (parts.subdir) |subdir| {
        defer std.fs.deleteTreeAbsolute(clone_dest) catch {};

        const subdir_path = try std.fs.path.join(allocator, &.{ clone_dest, subdir });
        defer allocator.free(subdir_path);

        // Verify the subdir exists before trying to copy it.
        std.fs.accessAbsolute(subdir_path, .{}) catch {
            const wmsg = try std.fmt.allocPrint(
                allocator,
                "git dep {s}: subdirectory '{s}' not found in repo",
                .{ name, subdir },
            );
            defer allocator.free(wmsg);
            writer.emit(.{ .warning = wmsg });
            return;
        };

        std.fs.deleteTreeAbsolute(dest) catch {};
        try copyPackageDir(allocator, subdir_path, dest);
    }
}

/// Copies all files from `src_dir` into `dest_dir` using hardlinks where
/// possible (same filesystem) or copies otherwise.
///
/// If `src_dir` cannot be opened (e.g. cache miss), the already-created
/// `dest_dir` is removed and the error is propagated so callers can warn and
/// skip this package rather than leaving an empty directory in node_modules.
fn copyPackageDir(allocator: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8) !void {
    std.fs.deleteTreeAbsolute(dest_dir) catch {};
    try fs_util.mkdirAllRecursive(allocator, dest_dir);

    var src = std.fs.openDirAbsolute(src_dir, .{ .iterate = true }) catch |err| {
        std.fs.deleteTreeAbsolute(dest_dir) catch {};
        return err;
    };
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
    writer: output.Writer,
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, "package.json" });
    defer allocator.free(manifest_path);

    var manifest = json_util.parseFile(allocator, manifest_path) catch |err| {
        if (err != error.FileNotFound) {
            const wmsg = std.fmt.allocPrint(
                allocator,
                "bin stubs: could not read {s}/package.json: {s}",
                .{ pkg_name, @errorName(err) },
            ) catch return;
            defer allocator.free(wmsg);
            writer.emit(.{ .warning = wmsg });
        }
        return;
    };
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
            platform.createBinStub(allocator, bin_dir, bin_name, script_path) catch |err| {
                const wmsg = std.fmt.allocPrint(
                    allocator,
                    "bin stubs: failed to create .bin/{s} for {s}: {s}",
                    .{ bin_name, pkg_name, @errorName(err) },
                ) catch return;
                defer allocator.free(wmsg);
                writer.emit(.{ .warning = wmsg });
            };
        },
        .map => |entries| {
            var it = entries.iterator();
            while (it.next()) |kv| {
                const script_path = try std.fs.path.join(allocator, &.{ pkg_dir, kv.value_ptr.* });
                defer allocator.free(script_path);
                platform.createBinStub(allocator, bin_dir, kv.key_ptr.*, script_path) catch |err| {
                    const wmsg = std.fmt.allocPrint(
                        allocator,
                        "bin stubs: failed to create .bin/{s} for {s}: {s}",
                        .{ kv.key_ptr.*, pkg_name, @errorName(err) },
                    ) catch return;
                    defer allocator.free(wmsg);
                    writer.emit(.{ .warning = wmsg });
                };
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
