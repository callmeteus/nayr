//! `nayr remove` Command
//!
//! Removes one or more packages from `package.json` and runs install.

const std = @import("std");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const install_cmd = @import("install.zig");
const integrity_mod = @import("../core/integrity.zig");
const Config = config_types.Config;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    var packages = std.ArrayList([]const u8).init(allocator);
    defer packages.deinit();

    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) try packages.append(arg);
    }

    if (packages.items.len == 0) {
        writer.emit(.{ .err = "nayr remove: no packages specified" });
        return error.NoPackagesSpecified;
    }

    const pkg_json_path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(pkg_json_path);

    const raw = blk: {
        const f = try std.fs.openFileAbsolute(pkg_json_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 4 * 1024 * 1024);
    };
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const dep_fields = [_][]const u8{
        "dependencies",
        "devDependencies",
        "peerDependencies",
        "optionalDependencies",
    };

    for (packages.items) |pkg_name| {
        var removed = false;
        for (dep_fields) |field| {
            if (parsed.value.object.getPtr(field)) |deps_val| {
                if (deps_val.* == .object) {
                    if (deps_val.object.fetchSwapRemove(pkg_name)) |_| {
                        removed = true;
                        writer.emit(.{ .info = try std.fmt.allocPrint(
                            allocator,
                            "removed {s} from {s}",
                            .{ pkg_name, field },
                        ) });
                    }
                }
            }
        }
        if (!removed) {
            writer.emit(.{ .warning = try std.fmt.allocPrint(
                allocator,
                "{s} is not in package.json",
                .{pkg_name},
            ) });
        }
    }

    // Write updated package.json.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{pkg_json_path});
    defer allocator.free(tmp_path);
    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        try std.json.stringify(parsed.value, .{ .whitespace = .indent_2 }, f.writer());
        try f.writeAll("\n");
    }
    try std.fs.renameAbsolute(tmp_path, pkg_json_path);

    // Invalidate integrity so the next install is forced.
    integrity_mod.invalidate(allocator, cwd);

    // Re-install to prune removed packages.
    try install_cmd.run(allocator, &.{}, cwd, config, writer);
}
