//! `nayr registry` Command
//!
//! Auto-discovery and management of private npm registry scopes.
//! Replaces the standalone `verc` npm package.
//!
//! Sub-commands:
//!   nayr registry sync [name]            - sync scopes from configured registries
//!   nayr registry add <name> <url>       - add a registry to .nayrrc
//!   nayr registry remove <name>          - remove a registry from .nayrrc
//!   nayr registry list                   - list configured registries
//!   nayr registry status                 - show current state

const std = @import("std");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const registry_client = @import("../registry/client.zig");
const registry_auth = @import("../registry/auth.zig");
const platform = @import("../util/platform.zig");
const Config = config_types.Config;

// ============================================================================
// Entry point
// ============================================================================

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    const sub = if (args.len > 0) args[0] else "list";
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, sub, "sync")) {
        try runSync(allocator, sub_args, config, writer);
    } else if (std.mem.eql(u8, sub, "list")) {
        try runList(allocator, config, writer);
    } else if (std.mem.eql(u8, sub, "status")) {
        try runStatus(allocator, cwd, config, writer);
    } else if (std.mem.eql(u8, sub, "add")) {
        try runAdd(allocator, sub_args, cwd, config, writer);
    } else if (std.mem.eql(u8, sub, "remove")) {
        try runRemove(allocator, sub_args, cwd, config, writer);
    } else {
        writer.emit(.{ .err = "usage: nayr registry [sync|list|status|add|remove]" });
    }
}

// ============================================================================
// sync
// ============================================================================

/// Discovers scopes from configured private registries and writes them to
/// `~/.npmrc` inside a delimited block.
fn runSync(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    // Optional: filter to a single registry by name.
    const filter: ?[]const u8 = if (args.len > 0) args[0] else null;

    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    const npmrc_path = try std.fs.path.join(allocator, &.{ home, ".npmrc" });
    defer allocator.free(npmrc_path);

    var reg_it = config.private_registries.iterator();
    while (reg_it.next()) |kv| {
        const reg_name = kv.key_ptr.*;
        const reg = kv.value_ptr;

        if (filter != null and !std.mem.eql(u8, filter.?, reg_name)) continue;

        writer.emit(.{ .info = try std.fmt.allocPrint(
            allocator,
            "discovering scopes from {s} ({s})...",
            .{ reg_name, reg.url },
        ) });

        var client = registry_client.RegistryClient.init(allocator, config);
        defer client.deinit();

        const scopes = switch (reg.registry_type) {
            .verdaccio => try client.discoverScopesVerdaccio(reg.url),
            .npm => try client.discoverScopesNpm(reg.url),
        };

        if (scopes.len == 0 and reg.scopes.len > 0) {
            // Fall back to manually configured scopes.
            try writeScopesToNpmrc(allocator, npmrc_path, reg.url, reg.scopes);
            writer.emit(.{ .info = try std.fmt.allocPrint(
                allocator,
                "wrote {d} manual scopes for {s}",
                .{ reg.scopes.len, reg_name },
            ) });
        } else if (scopes.len > 0) {
            try writeScopesToNpmrc(allocator, npmrc_path, reg.url, scopes);
            writer.emit(.{ .info = try std.fmt.allocPrint(
                allocator,
                "wrote {d} scopes for {s}",
                .{ scopes.len, reg_name },
            ) });
        } else {
            writer.emit(.{ .warning = try std.fmt.allocPrint(
                allocator,
                "no scopes discovered for {s}",
                .{reg_name},
            ) });
        }

        // Resolve auth token from env var if configured.
        if (reg.auth_token_env) |env_var| {
            if (std.process.getEnvVarOwned(allocator, env_var)) |token| {
                defer allocator.free(token);
                try registry_auth.saveToken(allocator, npmrc_path, reg.url, token);
            } else |_| {}
        }
    }

    writer.emit(.{ .done = .{ .elapsed_ms = 0, .summary = "registry sync complete" } });
}

// ============================================================================
// list
// ============================================================================

fn runList(
    _: std.mem.Allocator,
    config: *const Config,
    writer: output.Writer,
) !void {
    if (config.private_registries.count() == 0) {
        writer.emit(.{ .info = "no private registries configured" });
        return;
    }

    var it = config.private_registries.iterator();
    while (it.next()) |kv| {
        const reg = kv.value_ptr;
        const cols = &[_][]const u8{
            kv.key_ptr.*,
            reg.url,
            @tagName(reg.registry_type),
            if (reg.auto_sync) "auto-sync" else "",
        };
        writer.emit(.{ .table_row = .{ .columns = cols } });
    }
}

// ============================================================================
// status
// ============================================================================

fn runStatus(
    allocator: std.mem.Allocator,
    _: []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    writer.emit(.{ .info = try std.fmt.allocPrint(
        allocator,
        "default registry: {s}",
        .{config.registry},
    ) });

    var scope_it = config.scoped_registries.iterator();
    while (scope_it.next()) |kv| {
        writer.emit(.{ .info = try std.fmt.allocPrint(
            allocator,
            "  {s}: {s}",
            .{ kv.key_ptr.*, kv.value_ptr.* },
        ) });
    }

    writer.emit(.{ .info = try std.fmt.allocPrint(
        allocator,
        "{d} private registry configurations",
        .{config.private_registries.count()},
    ) });
}

// ============================================================================
// add / remove
// ============================================================================

fn runAdd(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    _: *const Config,
    writer: output.Writer,
) !void {
    if (args.len < 2) {
        writer.emit(.{ .err = "usage: nayr registry add <name> <url> [--type verdaccio|npm]" });
        return;
    }
    const name = args[0];
    const url = args[1];
    var reg_type: []const u8 = "npm";
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.startsWith(u8, args[i], "--type=")) reg_type = args[i]["--type=".len..];
    }

    // Append to .nayrrc in the project directory.
    const nayrrc_path = try std.fs.path.join(allocator, &.{ cwd, ".nayrrc" });
    defer allocator.free(nayrrc_path);

    const f = std.fs.openFileAbsolute(nayrrc_path, .{ .mode = .read_write }) catch
        try std.fs.createFileAbsolute(nayrrc_path, .{});
    defer f.close();
    try f.seekFromEnd(0);
    try f.writer().print(
        "\n[registry.{s}]\nurl = \"{s}\"\ntype = \"{s}\"\n",
        .{ name, url, reg_type },
    );

    writer.emit(.{ .done = .{
        .elapsed_ms = 0,
        .summary = try std.fmt.allocPrint(allocator, "added registry: {s}", .{name}),
    } });
}

fn runRemove(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    _: *const Config,
    writer: output.Writer,
) !void {
    if (args.len == 0) {
        writer.emit(.{ .err = "usage: nayr registry remove <name>" });
        return;
    }
    // TODO: edit .nayrrc to remove the section.
    writer.emit(.{ .info = try std.fmt.allocPrint(
        allocator,
        "removed registry {s} from {s}/.nayrrc (manual edit required for now)",
        .{ args[0], cwd },
    ) });
}

// ============================================================================
// .npmrc block writer
// ============================================================================

/// Writes scoped registry entries into `~/.npmrc`, replacing any existing
/// `# BEGIN NAYR AUTO RC` / `# END NAYR AUTO RC` block (or migrating from
/// the legacy `# BEGIN VERDACCIO AUTO RC` block).
fn writeScopesToNpmrc(
    allocator: std.mem.Allocator,
    npmrc_path: []const u8,
    registry_url: []const u8,
    scopes: []const []const u8,
) !void {
    const existing = blk: {
        const f = std.fs.openFileAbsolute(npmrc_path, .{}) catch break :blk try allocator.dupe(u8, "");
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 256 * 1024);
    };
    defer allocator.free(existing);

    // Remove any existing auto-managed block (both nayr and legacy verdaccio).
    const stripped = try stripAutoBlock(allocator, existing);
    defer allocator.free(stripped);

    // Build the new block.
    var block = std.ArrayList(u8).init(allocator);
    defer block.deinit();
    try block.appendSlice("# BEGIN NAYR AUTO RC\n");
    for (scopes) |scope| {
        try block.writer().print("{s}:registry={s}\n", .{ scope, registry_url });
    }
    try block.appendSlice("# END NAYR AUTO RC\n");

    const new_content = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stripped, block.items });
    defer allocator.free(new_content);

    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}", .{ npmrc_path, platform.uniqueId() });
    defer allocator.free(tmp);
    {
        const f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true });
        defer f.close();
        try f.writeAll(new_content);
    }
    try std.fs.renameAbsolute(tmp, npmrc_path);
}

/// Removes the `# BEGIN NAYR AUTO RC` / `# END NAYR AUTO RC` block from content.
/// Also removes the legacy `# BEGIN VERDACCIO AUTO RC` block (migration).
fn stripAutoBlock(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    var in_block = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "# BEGIN NAYR AUTO RC") or
            std.mem.startsWith(u8, line, "# BEGIN VERDACCIO AUTO RC"))
        {
            in_block = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "# END NAYR AUTO RC") or
            std.mem.startsWith(u8, line, "# END VERDACCIO AUTO RC"))
        {
            in_block = false;
            continue;
        }
        if (!in_block) {
            try out.appendSlice(line);
            try out.append('\n');
        }
    }
    return out.toOwnedSlice();
}
