//! `nayr publish` / `nayr pack` Commands
//!
//! Publishes a package to an npm-compatible registry or creates a local tarball.

const std = @import("std");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const publish_mod = @import("../registry/publish.zig");
const Config = config_types.Config;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    var opts = publish_mod.PublishOptions{};

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--tag=")) opts.tag = arg["--tag=".len..];
        if (std.mem.startsWith(u8, arg, "--access=")) {
            if (std.mem.eql(u8, arg["--access=".len..], "public")) opts.access = .public;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) opts.dry_run = true;
    }

    publish_mod.publish(allocator, config, cwd, opts) catch |err| {
        writer.emit(.{ .err = try std.fmt.allocPrint(allocator, "publish failed: {s}", .{@errorName(err)}) });
        return;
    };

    writer.emit(.{ .done = .{ .elapsed_ms = 0, .summary = "package published" } });
}

pub fn runPack(
    allocator: std.mem.Allocator,
    _: []const []const u8,
    cwd: []const u8,
    _: *const Config,
    writer: output.Writer,
) !void {
    var child = std.process.Child.init(
        &[_][]const u8{ "tar", "-czf", "package.tgz", "--transform", "s,^,package/,", "." },
        allocator,
    );
    child.cwd = cwd;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const result = try child.spawnAndWait();
    if (result == .Exited and result.Exited == 0) {
        writer.emit(.{ .done = .{ .elapsed_ms = 0, .summary = "created package.tgz" } });
    } else {
        writer.emit(.{ .err = "pack failed" });
    }
}
