//! `nayr link`, `nayr unlink`, `nayr mklink`, `nayr autolink` Commands
//!
//! Manages the local package link registry at `~/.nayr/links/`.
//!
//! Commands:
//!   nayr link              - register the current package
//!   nayr link <name>       - create a node_modules symlink to a registered pkg
//!   nayr unlink [name]     - remove a registration or node_modules link
//!   nayr mklink [glob]     - register multiple packages via glob
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
// nayr mklink
// ============================================================================

pub fn runMklink(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    _: *const Config,
    writer: output.Writer,
) !void {
    const links_dir = try platform.getLinksDir(allocator);
    defer allocator.free(links_dir);
    try fs_util.mkdirAllRecursive(allocator, links_dir);

    const glob = if (args.len > 0) args[0] else "packages/*";
    const matches = try fs_util.globExpand(allocator, cwd, glob);
    defer allocator.free(matches);

    for (matches) |match| {
        const pkg_json = try std.fs.path.join(allocator, &.{ match, "package.json" });
        defer allocator.free(pkg_json);
        std.fs.accessAbsolute(pkg_json, .{}) catch continue;

        const manifest = json_util.parseFile(allocator, pkg_json) catch continue;
        const name = manifest.name orelse continue;

        const link_path = try std.fs.path.join(allocator, &.{ links_dir, name });
        defer allocator.free(link_path);

        // Remove and recreate the symlink.
        std.fs.deleteFileAbsolute(link_path) catch {};
        std.fs.deleteTreeAbsolute(link_path) catch {};
        platform.symlinkOrJunction(match, link_path) catch |err| {
            writer.emit(.{ .warning = try std.fmt.allocPrint(
                allocator,
                "mklink: could not link {s}: {s}",
                .{ name, @errorName(err) },
            ) });
            continue;
        };
        writer.emit(.{ .info = try std.fmt.allocPrint(allocator, "registered link: {s} → {s}", .{ name, match }) });
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

    // Link all deps that have a registered entry.
    var linked: u32 = 0;
    var dep_it = manifest.dependencies.iterator();
    while (dep_it.next()) |kv| {
        const name = kv.key_ptr.*;
        const link_path = try std.fs.path.join(allocator, &.{ links_dir, name });
        defer allocator.free(link_path);

        std.fs.accessAbsolute(link_path, .{}) catch continue;
        try linkPackageIntoNodeModules(allocator, name, cwd, links_dir, writer);
        linked += 1;
    }

    if (linked == 0) {
        writer.emit(.{ .info = "no registered links match dependencies" });
    } else {
        writer.emit(.{ .done = .{
            .elapsed_ms = 0,
            .summary = try std.fmt.allocPrint(allocator, "{d} packages auto-linked", .{linked}),
        } });
    }
}

// ============================================================================
// Internal helpers
// ============================================================================

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

    // For scoped packages, ensure the scope directory exists.
    if (name[0] == '@') {
        const slash = std.mem.indexOfScalar(u8, name, '/') orelse return error.InvalidPackageName;
        const scope_dir = try std.fs.path.join(allocator, &.{ links_dir, name[0..slash] });
        defer allocator.free(scope_dir);
        try fs_util.mkdirAllRecursive(allocator, scope_dir);
    }

    const link_path = try std.fs.path.join(allocator, &.{ links_dir, name });
    defer allocator.free(link_path);

    std.fs.deleteFileAbsolute(link_path) catch {};
    std.fs.deleteTreeAbsolute(link_path) catch {};
    try platform.symlinkOrJunction(cwd, link_path);

    writer.emit(.{ .info = try std.fmt.allocPrint(allocator, "registered: {s} → {s}", .{ name, cwd }) });
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

    std.fs.accessAbsolute(link_src, .{}) catch {
        writer.emit(.{ .err = try std.fmt.allocPrint(allocator, "no link registered for: {s}", .{name}) });
        return;
    };

    const node_modules = try std.fs.path.join(allocator, &.{ cwd, "node_modules" });
    defer allocator.free(node_modules);
    try fs_util.mkdirAllRecursive(allocator, node_modules);

    // For scoped packages, ensure the scope dir exists.
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

    writer.emit(.{ .info = try std.fmt.allocPrint(allocator, "linked: {s}", .{name}) });
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
    writer.emit(.{ .info = try std.fmt.allocPrint(allocator, "unregistered: {s}", .{name}) });
}

fn listLinks(allocator: std.mem.Allocator, links_dir: []const u8, writer: output.Writer) !void {
    var dir = std.fs.openDirAbsolute(links_dir, .{ .iterate = true }) catch {
        writer.emit(.{ .info = "no links registered" });
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        writer.emit(.{ .info = try std.fmt.allocPrint(allocator, "  {s}", .{entry.name}) });
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
            writer.emit(.{ .info = try std.fmt.allocPrint(allocator, "removed broken link: {s}", .{entry.name}) });
        };
    }
}
