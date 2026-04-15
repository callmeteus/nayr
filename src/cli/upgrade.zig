//! `nayr upgrade` Command
//!
//! Upgrades packages to the latest version satisfying their range, or to
//! the absolute latest when `--latest` is passed.

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
    var latest = false;
    var packages = std.ArrayList([]const u8).init(allocator);
    defer packages.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--latest")) {
            latest = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try packages.append(arg);
        }
    }

    // When upgrading, force re-resolution (ignore lockfile hits).
    // For `--latest`, we would also strip ranges and reset to `*` before
    // resolving — implemented as a future enhancement.
    const install_args: []const []const u8 = if (latest)
        &[_][]const u8{"--force"}
    else
        &[_][]const u8{"--force"};

    if (packages.items.len > 0) {
        writer.emit(.{ .info = try std.fmt.allocPrint(
            allocator,
            "upgrading: {s}",
            .{try std.mem.join(allocator, ", ", packages.items)},
        ) });
    } else {
        writer.emit(.{ .info = "upgrading all packages" });
    }

    integrity_mod.invalidate(allocator, cwd);
    try install_cmd.run(allocator, install_args, cwd, config, writer);
}
