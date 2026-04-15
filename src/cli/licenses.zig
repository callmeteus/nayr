//! `nayr licenses list` Command
//!
//! Lists all installed packages and their SPDX license identifiers.

const std = @import("std");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const json_util = @import("../util/json.zig");
const Config = config_types.Config;

pub fn run(
    allocator: std.mem.Allocator,
    _: []const []const u8,
    cwd: []const u8,
    _: *const Config,
    writer: output.Writer,
) !void {
    const node_modules = try std.fs.path.join(allocator, &.{ cwd, "node_modules" });
    defer allocator.free(node_modules);

    var dir = std.fs.openDirAbsolute(node_modules, .{ .iterate = true }) catch {
        writer.emit(.{ .err = "node_modules not found - run nayr install first" });
        return;
    };
    defer dir.close();

    // Group packages by license.
    var license_map = std.StringHashMapUnmanaged(std.ArrayList([]const u8)){};
    defer {
        var it = license_map.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit();
        license_map.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;

        const pkg_dir = try std.fs.path.join(allocator, &.{ node_modules, entry.name });
        defer allocator.free(pkg_dir);

        try collectLicenses(allocator, pkg_dir, entry.name, &license_map);
    }

    // Emit as table rows.
    var it = license_map.iterator();
    while (it.next()) |kv| {
        for (kv.value_ptr.items) |pkg_name| {
            const cols = &[_][]const u8{ pkg_name, kv.key_ptr.* };
            writer.emit(.{ .table_row = .{ .columns = cols } });
        }
    }
}

fn collectLicenses(
    allocator: std.mem.Allocator,
    pkg_dir: []const u8,
    pkg_name: []const u8,
    map: *std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, "package.json" });
    defer allocator.free(manifest_path);

    const raw = std.fs.openFileAbsolute(manifest_path, .{}) catch return;
    defer raw.close();
    const content = raw.readToEndAlloc(allocator, 256 * 1024) catch return;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return;
    defer parsed.deinit();

    const license = blk: {
        if (parsed.value.object.get("license")) |lic| {
            if (lic == .string) break :blk lic.string;
        }
        break :blk "UNKNOWN";
    };

    const entry = try map.getOrPut(allocator, license);
    if (!entry.found_existing) {
        entry.value_ptr.* = std.ArrayList([]const u8).init(allocator);
    }
    try entry.value_ptr.append(try allocator.dupe(u8, pkg_name));
}
