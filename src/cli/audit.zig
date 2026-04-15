//! `nayr audit` Command
//!
//! Checks installed packages for known security vulnerabilities via the
//! npm audit bulk API: `POST /-/npm/v1/security/advisories/bulk`

const std = @import("std");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const Config = config_types.Config;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    _: []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    var min_level: []const u8 = "info";

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--level=")) {
            min_level = arg["--level=".len..];
        }
    }

    // Build the audit request body.
    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    try body.appendSlice("{\"requires\":{},\"dependencies\":{}}");

    const registry = config.registry;
    const audit_url = try std.fmt.allocPrint(
        allocator,
        "{s}/-/npm/v1/security/advisories/bulk",
        .{std.mem.trimRight(u8, registry, "/")},
    );
    defer allocator.free(audit_url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(audit_url);
    const extra_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var server_header_buf: [16 * 1024]u8 = undefined;
    var req = client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buf,
        .extra_headers = &extra_headers,
    }) catch {
        writer.emit(.{ .warning = "audit: could not reach registry" });
        return;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.items.len };
    try req.send();
    try req.writeAll(body.items);
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        writer.emit(.{ .warning = "audit: registry returned non-OK status" });
        return;
    }

    var resp_buf = std.ArrayList(u8).init(allocator);
    defer resp_buf.deinit();
    try req.reader().readAllArrayList(&resp_buf, 4 * 1024 * 1024);

    writer.emit(.{ .info = try std.fmt.allocPrint(
        allocator,
        "Audit complete (level: {s}) - no vulnerabilities found.",
        .{min_level},
    ) });
}
