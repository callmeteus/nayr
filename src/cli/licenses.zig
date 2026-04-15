//! `nayr licenses list` Command
//!
//! Lists all installed packages and their SPDX license identifiers by scanning
//! `node_modules` and reading each package's `package.json`.

const std = @import("std");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
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

    // Group packages by license. Keys and ArrayList items are heap-owned and
    // freed in the defer block below.
    var license_map = std.StringHashMapUnmanaged(std.ArrayList([]const u8)){};
    defer {
        var it = license_map.iterator();
        while (it.next()) |kv| {
            for (kv.value_ptr.items) |pkg| allocator.free(pkg);
            kv.value_ptr.deinit();
            allocator.free(kv.key_ptr.*);
        }
        license_map.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;

        const pkg_path = try std.fs.path.join(allocator, &.{ node_modules, entry.name });
        defer allocator.free(pkg_path);

        if (entry.name[0] == '@') {
            // Scoped package directory - recurse one level to find `@scope/pkg`.
            try collectScoped(allocator, pkg_path, entry.name, &license_map);
        } else {
            try collectOne(allocator, pkg_path, entry.name, &license_map);
        }
    }

    // Emit sorted table rows: package name | license.
    var sorted = std.ArrayList(struct { pkg: []const u8, lic: []const u8 }).init(allocator);
    defer sorted.deinit();

    var it = license_map.iterator();
    while (it.next()) |kv| {
        for (kv.value_ptr.items) |pkg_name| {
            try sorted.append(.{ .pkg = pkg_name, .lic = kv.key_ptr.* });
        }
    }

    std.mem.sort(
        @TypeOf(sorted.items[0]),
        sorted.items,
        {},
        struct {
            fn lt(_: void, a: @TypeOf(sorted.items[0]), b: @TypeOf(sorted.items[0])) bool {
                return std.mem.lessThan(u8, a.pkg, b.pkg);
            }
        }.lt,
    );

    for (sorted.items) |row| {
        const cols = &[_][]const u8{ row.pkg, row.lic };
        writer.emit(.{ .table_row = .{ .columns = cols } });
    }
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

/// Iterates a `@scope` directory and collects licenses for each sub-package.
fn collectScoped(
    allocator: std.mem.Allocator,
    scope_path: []const u8,
    scope_name: []const u8,
    map: *std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
) !void {
    var scope_dir = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch return;
    defer scope_dir.close();

    var iter = scope_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const full_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ scope_name, entry.name });
        defer allocator.free(full_name);

        const pkg_path = try std.fs.path.join(allocator, &.{ scope_path, entry.name });
        defer allocator.free(pkg_path);

        try collectOne(allocator, pkg_path, full_name, map);
    }
}

/// Reads a single package's `package.json` and inserts it into `map` keyed
/// by its license string.
///
/// The map owns both the license key and the package name value - both are
/// heap-allocated here and freed by the caller's defer block in `run`.
fn collectOne(
    allocator: std.mem.Allocator,
    pkg_dir: []const u8,
    pkg_name: []const u8,
    map: *std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, "package.json" });
    defer allocator.free(manifest_path);

    const file = std.fs.openFileAbsolute(manifest_path, .{}) catch return;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 256 * 1024) catch return;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return;
    defer parsed.deinit();

    // Extract license string. `parsed` is freed at the end of this function so
    // we must NOT store any slice that points into the parsed tree - dupe everything.
    const license_raw: []const u8 = blk: {
        if (parsed.value == .object) {
            if (parsed.value.object.get("license")) |lic| {
                if (lic == .string) break :blk lic.string;
                // Some packages use {"license": {"type": "MIT", ...}}
                if (lic == .object) {
                    if (lic.object.get("type")) |t| {
                        if (t == .string) break :blk t.string;
                    }
                }
            }
        }
        break :blk "UNKNOWN";
    };

    const entry = try map.getOrPut(allocator, license_raw);
    if (!entry.found_existing) {
        // Dupe the key: license_raw points into `parsed` which is freed below.
        entry.key_ptr.* = try allocator.dupe(u8, license_raw);
        entry.value_ptr.* = std.ArrayList([]const u8).init(allocator);
    }
    // Dupe pkg_name: it points into the caller's dir-iteration buffer.
    try entry.value_ptr.append(try allocator.dupe(u8, pkg_name));
}
