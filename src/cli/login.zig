//! `nayr login` / `nayr logout` Commands
//!
//! Multi-registry authentication — authenticates against one or more
//! registries in a single invocation (unlike Yarn Classic which supports
//! only one registry per login).
//!
//! Usage:
//!   nayr login                                         — login to default registry
//!   nayr login --registry http://npm.arpa              — login to a specific registry
//!   nayr login --registry http://npm.arpa --registry https://npm.pkg.github.com
//!   nayr login --registry private                      — alias from .nayrrc
//!   nayr login --list                                  — list active sessions
//!   nayr logout --registry http://npm.arpa
//!   nayr logout --all

const std = @import("std");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const registry_auth = @import("../registry/auth.zig");
const platform = @import("../util/platform.zig");
const Config = config_types.Config;

// ============================================================================
// login
// ============================================================================

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    _: []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    // --list flag: show active sessions.
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--list")) {
            try listSessions(allocator, config, writer);
            return;
        }
    }

    // Collect --registry flags.
    var registries = std.ArrayList([]const u8).init(allocator);
    defer registries.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--registry") and i + 1 < args.len) {
            i += 1;
            const arg = args[i];
            // Resolve alias from .nayrrc.
            const url = if (config.private_registries.get(arg)) |reg| reg.url else arg;
            try registries.append(url);
        }
    }

    if (registries.items.len == 0) {
        // Default to the configured registry.
        try registries.append(config.registry);
    }

    // Prompt for credentials (interactive).
    const username = try promptInput(allocator, "Username: ");
    defer allocator.free(username);
    const password = try promptPassword(allocator, "Password: ");
    defer allocator.free(password);
    const email = try promptInput(allocator, "Email: ");
    defer allocator.free(email);

    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    const npmrc_path = try std.fs.path.join(allocator, &.{ home, ".npmrc" });
    defer allocator.free(npmrc_path);

    for (registries.items) |registry_url| {
        writer.emit(.{ .info = try std.fmt.allocPrint(
            allocator,
            "authenticating to {s}...",
            .{registry_url},
        ) });

        const token = registry_auth.login(allocator, registry_url, username, password, email) catch |err| {
            writer.emit(.{ .err = try std.fmt.allocPrint(
                allocator,
                "login failed for {s}: {s}",
                .{ registry_url, @errorName(err) },
            ) });
            continue;
        };
        defer allocator.free(token);

        try registry_auth.saveToken(allocator, npmrc_path, registry_url, token);
        writer.emit(.{ .done = .{
            .elapsed_ms = 0,
            .summary = try std.fmt.allocPrint(allocator, "logged in to {s}", .{registry_url}),
        } });
    }
}

// ============================================================================
// logout
// ============================================================================

pub fn runLogout(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    _: []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    const npmrc_path = try std.fs.path.join(allocator, &.{ home, ".npmrc" });
    defer allocator.free(npmrc_path);

    var all = false;
    var registries = std.ArrayList([]const u8).init(allocator);
    defer registries.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--all")) {
            all = true;
        } else if (std.mem.eql(u8, args[i], "--registry") and i + 1 < args.len) {
            i += 1;
            const url = if (config.private_registries.get(args[i])) |r| r.url else args[i];
            try registries.append(url);
        }
    }

    if (all) {
        // Remove all auth entries.
        for (config.auth_entries.items) |entry| {
            registry_auth.removeToken(allocator, npmrc_path, entry.host) catch {};
            writer.emit(.{ .info = try std.fmt.allocPrint(allocator, "logged out from {s}", .{entry.host}) });
        }
        return;
    }

    if (registries.items.len == 0) {
        try registries.append(config.registry);
    }

    for (registries.items) |url| {
        try registry_auth.removeToken(allocator, npmrc_path, url);
        writer.emit(.{ .done = .{
            .elapsed_ms = 0,
            .summary = try std.fmt.allocPrint(allocator, "logged out from {s}", .{url}),
        } });
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn listSessions(
    _: std.mem.Allocator,
    config: *const Config,
    writer: output.Writer,
) !void {
    if (config.auth_entries.items.len == 0) {
        writer.emit(.{ .info = "no active sessions" });
        return;
    }
    for (config.auth_entries.items) |entry| {
        const has_token = entry.token != null or entry.basic != null;
        const cols = &[_][]const u8{
            entry.host,
            if (has_token) "authenticated" else "no token",
        };
        writer.emit(.{ .table_row = .{ .columns = cols } });
    }
}

/// Prompts the user for a plain-text input line.
fn promptInput(allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll(prompt);
    const stdin = std.io.getStdIn().reader();
    const line = try stdin.readUntilDelimiterAlloc(allocator, '\n', 256);
    return std.mem.trimRight(u8, line, "\r\n");
}

/// Prompts for a password with echo disabled (best-effort on Linux).
fn promptPassword(allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll(prompt);
    // Disable echo.
    disableEcho();
    defer enableEcho();
    const stdin = std.io.getStdIn().reader();
    const line = try stdin.readUntilDelimiterAlloc(allocator, '\n', 256);
    try stderr.writeAll("\n");
    return std.mem.trimRight(u8, line, "\r\n");
}

fn disableEcho() void {
    var termios = std.posix.tcgetattr(std.io.getStdIn().handle) catch return;
    termios.lflag.ECHO = false;
    std.posix.tcsetattr(std.io.getStdIn().handle, .NOW, termios) catch {};
}

fn enableEcho() void {
    var termios = std.posix.tcgetattr(std.io.getStdIn().handle) catch return;
    termios.lflag.ECHO = true;
    std.posix.tcsetattr(std.io.getStdIn().handle, .NOW, termios) catch {};
}
