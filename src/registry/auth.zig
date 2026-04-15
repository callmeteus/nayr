//! Registry Authentication
//!
//! Implements the npm authentication protocol (`PUT /-/user/…`) used by
//! `nayr login`, and utilities for reading/writing tokens to `.npmrc`.

const std = @import("std");
const config_types = @import("../config/types.zig");
const Config = config_types.Config;

// ============================================================================
// Login
// ============================================================================

/// Authenticates against a single registry and returns the auth token.
///
/// Uses the CouchDB user API, which is the standard npm login protocol:
/// `PUT /-/user/org.couchdb.user:<username>`
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `registry_url`: Base URL of the registry (e.g. `"http://npm.arpa"`).
/// - `username`: The npm username.
/// - `password`: The npm password.
/// - `email`: The user's email address.
///
/// ## Returns
/// The auth token returned by the registry.
pub fn login(
    allocator: std.mem.Allocator,
    registry_url: []const u8,
    username: []const u8,
    password: []const u8,
    email: []const u8,
) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/-/user/org.couchdb.user:{s}",
        .{ std.mem.trimRight(u8, registry_url, "/"), username },
    );
    defer allocator.free(url);

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"{s}\",\"password\":\"{s}\",\"email\":\"{s}\",\"type\":\"user\"}}",
        .{ username, password, email },
    );
    defer allocator.free(body);

    var response_buf = std.ArrayList(u8).init(allocator);
    defer response_buf.deinit();

    const uri = try std.Uri.parse(url);

    const extra_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
    };

    var server_header_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.PUT, uri, .{
        .server_header_buffer = &server_header_buf,
        .extra_headers = &extra_headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    try req.send();
    try req.writeAll(body);
    try req.finish();
    try req.wait();

    if (req.response.status != .ok and req.response.status != .created) {
        return error.LoginFailed;
    }

    try req.reader().readAllArrayList(&response_buf, 64 * 1024);

    // Parse response: `{"token": "..."}`.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_buf.items, .{});
    defer parsed.deinit();

    const token_val = parsed.value.object.get("token") orelse return error.NoTokenInResponse;
    if (token_val != .string) return error.NoTokenInResponse;

    return allocator.dupe(u8, token_val.string);
}

// ============================================================================
// .npmrc token persistence
// ============================================================================

/// Writes an auth token for the given registry into `~/.npmrc`.
///
/// Uses the lock-free write strategy: read → modify in-memory → write to
/// `<path>.tmp.<pid>` → atomic rename.
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `npmrc_path`: Absolute path to the `.npmrc` file to update.
/// - `registry_url`: Registry base URL (used to derive the `//host/` key).
/// - `token`: The auth token to persist.
pub fn saveToken(
    allocator: std.mem.Allocator,
    npmrc_path: []const u8,
    registry_url: []const u8,
    token: []const u8,
) !void {
    // Read existing .npmrc content (may not exist yet).
    var existing_content: []const u8 = "";
    if (std.fs.openFileAbsolute(npmrc_path, .{})) |f| {
        defer f.close();
        existing_content = try f.readToEndAlloc(allocator, 256 * 1024);
    } else |err| {
        if (err != error.FileNotFound) return err;
    }
    defer if (existing_content.len > 0) allocator.free(existing_content);

    // Build the `//host/:_authToken=<token>` key.
    const host_key = try registryHostKey(allocator, registry_url);
    defer allocator.free(host_key);
    const new_line = try std.fmt.allocPrint(allocator, "{s}:_authToken={s}", .{ host_key, token });
    defer allocator.free(new_line);

    // Rebuild the .npmrc content, replacing the existing token line if present.
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    var found = false;
    var it = std.mem.splitScalar(u8, existing_content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, host_key) and std.mem.indexOf(u8, line, "_authToken") != null) {
            // Replace existing token line.
            try out.appendSlice(new_line);
            try out.append('\n');
            found = true;
        } else {
            if (line.len > 0 or !found) {
                try out.appendSlice(line);
                try out.append('\n');
            }
        }
    }

    if (!found) {
        try out.appendSlice(new_line);
        try out.append('\n');
    }

    // Atomic write via temp file + rename.
    const pid = std.os.linux.getpid();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ npmrc_path, pid });
    defer allocator.free(tmp_path);

    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(out.items);
    }

    try std.fs.renameAbsolute(tmp_path, npmrc_path);
}

/// Removes the auth token for the given registry from `.npmrc`.
pub fn removeToken(
    allocator: std.mem.Allocator,
    npmrc_path: []const u8,
    registry_url: []const u8,
) !void {
    const host_key = try registryHostKey(allocator, registry_url);
    defer allocator.free(host_key);

    const existing = std.fs.openFileAbsolute(npmrc_path, .{}) catch return;
    const content = try existing.readToEndAlloc(allocator, 256 * 1024);
    existing.close();
    defer allocator.free(content);

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, host_key) and std.mem.indexOf(u8, line, "_authToken") != null) {
            continue; // skip this line
        }
        try out.appendSlice(line);
        try out.append('\n');
    }

    const pid = std.os.linux.getpid();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ npmrc_path, pid });
    defer allocator.free(tmp_path);

    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(out.items);
    }

    try std.fs.renameAbsolute(tmp_path, npmrc_path);
}

// ============================================================================
// Helpers
// ============================================================================

/// Converts a registry URL to the `.npmrc` host key format: `//host/`.
///
/// Examples:
///   `http://npm.arpa`      → `//npm.arpa/`
///   `https://registry.npmjs.org` → `//registry.npmjs.org/`
fn registryHostKey(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var host = url;
    if (std.mem.startsWith(u8, host, "https://")) host = host[8..];
    if (std.mem.startsWith(u8, host, "http://")) host = host[7..];
    host = std.mem.trimRight(u8, host, "/");
    return std.fmt.allocPrint(allocator, "//{s}/", .{host});
}
