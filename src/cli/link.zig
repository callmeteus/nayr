//! `nayr link`, `nayr unlink`, `nayr autolink` Commands
//!
//! Manages the local package link registry at `~/.nayr/links/`.
//!
//! Commands:
//!   nayr link              - register the current package globally
//!   nayr link <name>       - create a node_modules symlink to a registered pkg
//!   nayr unlink            - unregister the current package
//!   nayr unlink <name>     - remove a specific registration
//!   nayr autolink          - auto-link all registered packages present in pkg.json
//!   nayr link --list       - list all registered links
//!   nayr link --clean      - remove broken links

const std = @import("std");
const platform = @import("../util/platform.zig");
const fs_util = @import("../util/fs.zig");
const json_util = @import("../util/json.zig");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const Config = config_types.Config;

// ============================================================================
// nayr link
// ============================================================================

pub fn runLink(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    _: *const Config,
    writer: output.Writer,
) !void {
    const links_dir = try platform.getLinksDir(allocator);
    defer allocator.free(links_dir);
    try fs_util.mkdirAllRecursive(allocator, links_dir);

    // --list flag.
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--list")) {
            try listLinks(allocator, links_dir, writer);
            return;
        }
        if (std.mem.eql(u8, arg, "--clean")) {
            try cleanLinks(allocator, links_dir, writer);
            return;
        }
    }

    if (args.len == 0) {
        // Register the current directory as a link.
        try registerCurrentPackage(allocator, cwd, links_dir, writer);
    } else {
        // Link a registered package into node_modules.
        try linkPackageIntoNodeModules(allocator, args[0], cwd, links_dir, writer);
    }
}

// ============================================================================
// nayr unlink
// ============================================================================

pub fn runUnlink(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    _: *const Config,
    writer: output.Writer,
) !void {
    const links_dir = try platform.getLinksDir(allocator);
    defer allocator.free(links_dir);

    if (args.len == 0) {
        // Unregister the current package.
        const manifest_path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
        defer allocator.free(manifest_path);
        const manifest = json_util.parseFile(allocator, manifest_path) catch {
            writer.emit(.{ .err = "no package.json found" });
            return;
        };
        const name = manifest.name orelse {
            writer.emit(.{ .err = "package.json has no name field" });
            return;
        };
        try removeLinkEntry(allocator, links_dir, name, writer);
    } else {
        try removeLinkEntry(allocator, links_dir, args[0], writer);
    }
}

// ============================================================================
// nayr autolink
// ============================================================================

pub fn runAutolink(
    allocator: std.mem.Allocator,
    _: []const []const u8,
    cwd: []const u8,
    _: *const Config,
    writer: output.Writer,
) !void {
    const links_dir = try platform.getLinksDir(allocator);
    defer allocator.free(links_dir);

    const manifest_path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(manifest_path);
    const manifest = json_util.parseFile(allocator, manifest_path) catch {
        writer.emit(.{ .err = "no package.json found in current directory" });
        return;
    };

    // Link all deps that have a registered entry (nayr or yarn fallback).
    var linked: u32 = 0;
    var dep_it = manifest.dependencies.iterator();
    while (dep_it.next()) |kv| {
        const name = kv.key_ptr.*;
        const link_path = try std.fs.path.join(allocator, &.{ links_dir, name });
        defer allocator.free(link_path);

        const in_nayr = if (std.fs.accessAbsolute(link_path, .{})) |_| true else |_| false;
        if (!in_nayr) {
            // Check yarn as fallback; importFromYarn registers it if found.
            const imported = try importFromYarn(allocator, name, links_dir, writer);
            if (!imported) continue;
        }
        try linkPackageIntoNodeModules(allocator, name, cwd, links_dir, writer);
        linked += 1;
    }

    if (linked == 0) {
        writer.emit(.{ .info = "no registered links match dependencies" });
    } else {
        const summary = try std.fmt.allocPrint(allocator, "{d} packages auto-linked", .{linked});
        defer allocator.free(summary);
        writer.emit(.{ .done = .{ .elapsed_ms = 0, .summary = summary } });
    }
}

// ============================================================================
// Install-time relink helper
// ============================================================================

/// Applies any registered links for packages listed in `cwd`'s manifest.
///
/// Called during `nayr install` before the integrity fast-path so that a
/// newly registered link (e.g. from running `nayr install` in a sibling
/// package that auto-linked itself) is picked up even when the rest of
/// node_modules is already up-to-date.
///
/// Checks all dependency categories: dependencies, devDependencies,
/// optionalDependencies, and peerDependencies.  Silently skips packages
/// not present in any registry; only emits output when a link is actually
/// applied or updated.
pub fn applyRegisteredLinks(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    writer: output.Writer,
) !void {
    const links_dir = try platform.getLinksDir(allocator);
    defer allocator.free(links_dir);

    const manifest_path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(manifest_path);

    var manifest = json_util.parseFile(allocator, manifest_path) catch return;
    defer manifest.deinit(allocator);

    const all_maps = [_]*json_util.PackageJson.StringMap{
        &manifest.dependencies,
        &manifest.dev_dependencies,
        &manifest.optional_dependencies,
        &manifest.peer_dependencies,
    };

    for (all_maps) |dep_map| {
        var it = dep_map.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;

            const link_path = try std.fs.path.join(allocator, &.{ links_dir, name });
            defer allocator.free(link_path);

            const in_nayr = if (std.fs.accessAbsolute(link_path, .{})) |_| true else |_| false;
            if (!in_nayr) {
                // Check yarn as fallback; importFromYarn registers it if found.
                const imported = try importFromYarn(allocator, name, links_dir, writer);
                if (!imported) continue;
            }

            // Verify that the current node_modules entry is already a valid
            // symlink pointing to the registered target. Skip if it is so we
            // don't emit noise on every install.
            const dest = try std.fs.path.join(allocator, &.{ cwd, "node_modules", name });
            defer allocator.free(dest);
            const reg_target = platform.readSymlinkAbsolute(allocator, link_path) catch {
                try linkPackageIntoNodeModules(allocator, name, cwd, links_dir, writer);
                continue;
            };
            defer allocator.free(reg_target);

            const current = platform.readSymlinkAbsolute(allocator, dest) catch {
                // dest is not a symlink (missing, or a plain directory) - create it.
                try linkPackageIntoNodeModules(allocator, name, cwd, links_dir, writer);
                continue;
            };
            defer allocator.free(current);

            if (!std.mem.eql(u8, current, reg_target)) {
                // Points to a different target (stale link) - update it.
                try linkPackageIntoNodeModules(allocator, name, cwd, links_dir, writer);
            }
            // If targets match, the symlink is already correct - do nothing.
        }
    }
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Registers `cwd` as a global link for the package named `name`.
///
/// Called both by `nayr link` (interactive) and by the auto-link logic in
/// `nayr install` when the package name matches a `[links]` glob in `.nayrrc`.
pub fn registerPackage(
    allocator: std.mem.Allocator,
    name: []const u8,
    cwd: []const u8,
    writer: output.Writer,
) !void {
    const links_dir = try platform.getLinksDir(allocator);
    defer allocator.free(links_dir);
    try fs_util.mkdirAllRecursive(allocator, links_dir);
    try registerNamedPackage(allocator, name, cwd, links_dir, writer);
}

fn registerCurrentPackage(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    links_dir: []const u8,
    writer: output.Writer,
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(manifest_path);
    const manifest = json_util.parseFile(allocator, manifest_path) catch {
        writer.emit(.{ .err = "no package.json in current directory" });
        return;
    };
    const name = manifest.name orelse {
        writer.emit(.{ .err = "package.json has no name field" });
        return;
    };
    try registerNamedPackage(allocator, name, cwd, links_dir, writer);
}

fn registerNamedPackage(
    allocator: std.mem.Allocator,
    name: []const u8,
    cwd: []const u8,
    links_dir: []const u8,
    writer: output.Writer,
) !void {
    // For scoped packages, ensure the scope directory exists.
    if (name[0] == '@') {
        const slash = std.mem.indexOfScalar(u8, name, '/') orelse return error.InvalidPackageName;
        const scope_dir = try std.fs.path.join(allocator, &.{ links_dir, name[0..slash] });
        defer allocator.free(scope_dir);
        try fs_util.mkdirAllRecursive(allocator, scope_dir);
    }

    const link_path = try std.fs.path.join(allocator, &.{ links_dir, name });
    defer allocator.free(link_path);

    // If already pointing to this exact directory, skip silently.
    if (platform.readSymlinkAbsolute(allocator, link_path)) |existing| {
        defer allocator.free(existing);
        if (std.mem.eql(u8, existing, cwd)) return;
    } else |_| {}

    std.fs.deleteFileAbsolute(link_path) catch {};
    std.fs.deleteTreeAbsolute(link_path) catch {};
    try platform.symlinkOrJunction(cwd, link_path);

    const msg = try std.fmt.allocPrint(allocator, "registered: {s} → {s}", .{ name, cwd });
    defer allocator.free(msg);
    writer.emit(.{ .info = msg });
}

fn linkPackageIntoNodeModules(
    allocator: std.mem.Allocator,
    name: []const u8,
    cwd: []const u8,
    links_dir: []const u8,
    writer: output.Writer,
) !void {
    const link_src = try std.fs.path.join(allocator, &.{ links_dir, name });
    defer allocator.free(link_src);

    var imported_from_yarn = false;

    if (std.fs.accessAbsolute(link_src, .{})) |_| {
        // Found in nayr's registry - use it directly.
    } else |_| {
        // Not in nayr's registry - try to inherit from Yarn.
        if (try importFromYarn(allocator, name, links_dir, writer)) {
            imported_from_yarn = true;
        } else {
            const emsg = try std.fmt.allocPrint(allocator, "no link registered for: {s}", .{name});
            defer allocator.free(emsg);
            writer.emit(.{ .err = emsg });
            return;
        }
    }

    const node_modules = try std.fs.path.join(allocator, &.{ cwd, "node_modules" });
    defer allocator.free(node_modules);
    try fs_util.mkdirAllRecursive(allocator, node_modules);

    if (name[0] == '@') {
        const slash = std.mem.indexOfScalar(u8, name, '/') orelse return error.InvalidPackageName;
        const scope_nm = try std.fs.path.join(allocator, &.{ node_modules, name[0..slash] });
        defer allocator.free(scope_nm);
        try fs_util.mkdirAllRecursive(allocator, scope_nm);
    }

    const dest = try std.fs.path.join(allocator, &.{ node_modules, name });
    defer allocator.free(dest);

    std.fs.deleteTreeAbsolute(dest) catch {};
    try platform.symlinkOrJunction(link_src, dest);

    const link_msg = if (imported_from_yarn)
        try std.fmt.allocPrint(allocator, "linked: {s}  (inherited from yarn - registered in nayr)", .{name})
    else
        try std.fmt.allocPrint(allocator, "linked: {s}", .{name});
    defer allocator.free(link_msg);
    writer.emit(.{ .info = link_msg });
}

/// Attempts to find `name` in Yarn's link registry and register it in nayr's.
///
/// Returns `true` when the import succeeded; `false` when the package was not
/// found in Yarn's registry (no error is emitted - caller decides messaging).
fn importFromYarn(
    allocator: std.mem.Allocator,
    name: []const u8,
    nayr_links_dir: []const u8,
    writer: output.Writer,
) !bool {
    const yarn_dir = platform.getYarnLinksDir(allocator) catch return false;
    defer allocator.free(yarn_dir);

    const yarn_link = try std.fs.path.join(allocator, &.{ yarn_dir, name });
    defer allocator.free(yarn_link);

    std.fs.accessAbsolute(yarn_link, .{}) catch return false;

    const target = platform.readSymlinkAbsolute(allocator, yarn_link) catch return false;
    defer allocator.free(target);

    // Ensure scope dir exists inside nayr's links dir.
    if (name[0] == '@') {
        const slash = std.mem.indexOfScalar(u8, name, '/') orelse return false;
        const scope_dir = try std.fs.path.join(allocator, &.{ nayr_links_dir, name[0..slash] });
        defer allocator.free(scope_dir);
        try fs_util.mkdirAllRecursive(allocator, scope_dir);
    }

    const nayr_link = try std.fs.path.join(allocator, &.{ nayr_links_dir, name });
    defer allocator.free(nayr_link);

    std.fs.deleteFileAbsolute(nayr_link) catch {};
    std.fs.deleteTreeAbsolute(nayr_link) catch {};
    platform.symlinkOrJunction(target, nayr_link) catch |err| {
        const wmsg = std.fmt.allocPrint(allocator, "could not import yarn link for {s}: {s}", .{ name, @errorName(err) }) catch return false;
        defer allocator.free(wmsg);
        writer.emit(.{ .warning = wmsg });
        return false;
    };

    return true;
}

/// Walks a links directory (depth-2 for scoped packages) and calls `cb` for
/// every registered entry. `user_data` is passed through to the callback.
///
/// The callback signature is:
///   fn(allocator, scoped_name: []const u8, target_path: []const u8, user_data: *anyopaque) !void
fn walkLinksDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    user_data: *anyopaque,
    comptime cb: fn (std.mem.Allocator, []const u8, []const u8, *anyopaque) anyerror!void,
) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .sym_link) {
            const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(full);
            const target = platform.readSymlinkAbsolute(allocator, full) catch continue;
            defer allocator.free(target);
            try cb(allocator, entry.name, target, user_data);
        } else if (entry.kind == .directory and entry.name[0] == '@') {
            // One level deeper for scoped packages.
            const scope_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(scope_path);
            var scope_dir = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch continue;
            defer scope_dir.close();
            var scope_iter = scope_dir.iterate();
            while (try scope_iter.next()) |se| {
                if (se.kind != .sym_link) continue;
                const full_scoped = try std.fs.path.join(allocator, &.{ scope_path, se.name });
                defer allocator.free(full_scoped);
                const target = platform.readSymlinkAbsolute(allocator, full_scoped) catch continue;
                defer allocator.free(target);
                const scoped_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, se.name });
                defer allocator.free(scoped_name);
                try cb(allocator, scoped_name, target, user_data);
            }
        }
    }
}

fn removeLinkEntry(
    allocator: std.mem.Allocator,
    links_dir: []const u8,
    name: []const u8,
    writer: output.Writer,
) !void {
    const link_path = try std.fs.path.join(allocator, &.{ links_dir, name });
    defer allocator.free(link_path);

    std.fs.deleteFileAbsolute(link_path) catch {};
    std.fs.deleteTreeAbsolute(link_path) catch {};
    const umsg = try std.fmt.allocPrint(allocator, "unregistered: {s}", .{name});
    defer allocator.free(umsg);
    writer.emit(.{ .info = umsg });
}

const ListCtx = struct {
    arena: std.mem.Allocator,
    writer: output.Writer,
    seen: *std.StringHashMapUnmanaged(void),
    seen_base: std.mem.Allocator,
    count: *usize,
};

fn listLinksCb(
    arena: std.mem.Allocator,
    name: []const u8,
    target: []const u8,
    user_data: *anyopaque,
) !void {
    const ctx: *ListCtx = @alignCast(@ptrCast(user_data));
    const name_owned = try ctx.seen_base.dupe(u8, name);
    try ctx.seen.put(ctx.seen_base, name_owned, {});
    ctx.count.* += 1;
    ctx.writer.emit(.{ .info = try std.fmt.allocPrint(arena, "  {s} → {s}", .{ name, target }) });
}

fn listLinks(allocator: std.mem.Allocator, links_dir: []const u8, writer: output.Writer) !void {
    // Use an arena so all allocPrint strings (passed to writer) are freed at once.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var seen = std.StringHashMapUnmanaged(void){};
    defer {
        var kit = seen.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        seen.deinit(allocator);
    }

    var total: usize = 0;

    var nayr_ctx = ListCtx{
        .arena = arena,
        .writer = writer,
        .seen = &seen,
        .seen_base = allocator,
        .count = &total,
    };
    try walkLinksDir(arena, links_dir, @ptrCast(&nayr_ctx), listLinksCb);

    const nayr_count = total;

    // Also enumerate Yarn links not yet imported into nayr.
    const yarn_dir = platform.getYarnLinksDir(allocator) catch null;
    var yarn_pending: usize = 0;
    if (yarn_dir) |yd| {
        defer allocator.free(yd);

        const YarnCtx = struct {
            arena: std.mem.Allocator,
            writer: output.Writer,
            seen_ref: *std.StringHashMapUnmanaged(void),
            pending: *usize,

            fn cb(
                a: std.mem.Allocator,
                name: []const u8,
                target: []const u8,
                ud: *anyopaque,
            ) !void {
                const self: *@This() = @alignCast(@ptrCast(ud));
                if (self.seen_ref.contains(name)) return;
                self.writer.emit(.{ .info = try std.fmt.allocPrint(
                    a,
                    "  {s} → {s}  \x1b[2m(yarn, not yet imported)\x1b[0m",
                    .{ name, target },
                ) });
                self.pending.* += 1;
            }
        };
        var yctx = YarnCtx{
            .arena = arena,
            .writer = writer,
            .seen_ref = &seen,
            .pending = &yarn_pending,
        };
        try walkLinksDir(arena, yd, @ptrCast(&yctx), YarnCtx.cb);

        if (yarn_pending > 0) {
            writer.emit(.{ .info = "  hint: run `nayr link <name>` to import any yarn link into nayr" });
        }
    }

    if (nayr_count == 0 and yarn_pending == 0) {
        writer.emit(.{ .info = "no links registered" });
    }
}

fn cleanLinks(allocator: std.mem.Allocator, links_dir: []const u8, writer: output.Writer) !void {
    var dir = std.fs.openDirAbsolute(links_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full = try std.fs.path.join(allocator, &.{ links_dir, entry.name });
        defer allocator.free(full);
        // A broken symlink has no accessible target.
        std.fs.accessAbsolute(full, .{}) catch {
            std.fs.deleteFileAbsolute(full) catch {};
            const cmsg = try std.fmt.allocPrint(allocator, "removed broken link: {s}", .{entry.name});
            defer allocator.free(cmsg);
            writer.emit(.{ .info = cmsg });
        };
    }
}
