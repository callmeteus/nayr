//! `nayr why` Command
//!
//! Explains why a package is installed by showing all dependency paths
//! that lead to it in the resolved package tree.

const std = @import("std");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const nayr_fmt = @import("../lockfile/nayr_format.zig");
const Config = config_types.Config;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    _: *const Config,
    writer: output.Writer,
) !void {
    if (args.len == 0) {
        writer.emit(.{ .err = "usage: nayr why <package-name>" });
        return error.MissingArgument;
    }

    const target = args[0];

    const lockfile_path = try std.fs.path.join(allocator, &.{ cwd, "nayr.lock" });
    defer allocator.free(lockfile_path);

    const lock = nayr_fmt.parseFile(allocator, lockfile_path) catch {
        writer.emit(.{ .err = "no lockfile found — run nayr install first" });
        return;
    };

    // Search for all entries that match the target package name.
    var found = false;
    for (lock.entries) |entry| {
        for (entry.patterns) |pat| {
            const at = std.mem.lastIndexOfScalar(u8, pat, '@') orelse pat.len;
            const name = if (at > 0 and pat[0] != '@') pat[0..at] else blk: {
                const second_at = std.mem.indexOfScalarPos(u8, pat, 1, '@') orelse break :blk pat;
                break :blk pat[0..second_at];
            };

            if (std.mem.eql(u8, name, target)) {
                found = true;
                writer.emit(.{ .tree_node = .{ .depth = 0, .label = try std.fmt.allocPrint(
                    allocator,
                    "{s}@{s}",
                    .{ name, entry.version },
                ) } });

                // Show all packages that depend on this one.
                for (lock.entries) |other| {
                    if (other.dependencies.get(target) != null) {
                        writer.emit(.{ .tree_node = .{
                            .depth = 1,
                            .label = try std.fmt.allocPrint(allocator, "required by {s}", .{
                                if (other.patterns.len > 0) other.patterns[0] else "unknown",
                            }),
                        } });
                    }
                }
                break;
            }
        }
    }

    if (!found) {
        writer.emit(.{ .warning = try std.fmt.allocPrint(
            allocator,
            "{s} is not installed",
            .{target},
        ) });
    }
}
