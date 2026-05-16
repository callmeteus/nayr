//! `nayr workspace` and `nayr workspaces` Commands
//!
//! Workspace-level operations:
//!   nayr workspace <name> <command>  - run a command in a specific workspace
//!   nayr workspaces info             - list all workspaces and their versions
//!   nayr workspaces run <script>     - run a script in all workspaces

const std = @import("std");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const ws_discovery = @import("../workspace/discovery.zig");
const platform = @import("../util/platform.zig");
const Config = config_types.Config;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    if (args.len == 0) {
        writer.emit(.{ .err = "usage: nayr workspace <name> <command> | nayr workspaces info | nayr workspaces run <script>" });
        return;
    }

    const sub = args[0];

    if (std.mem.eql(u8, sub, "info")) {
        try runInfo(allocator, cwd, writer);
        return;
    }

    if (std.mem.eql(u8, sub, "run") and args.len > 1) {
        try runScriptAll(allocator, args[1..], cwd, writer);
        return;
    }

    // `nayr workspace <name> <cmd> [args...]`
    if (args.len >= 2) {
        const ws_name = sub;
        const cmd_args = args[1..];
        try runInWorkspace(allocator, ws_name, cmd_args, cwd, config, writer);
        return;
    }

    writer.emit(.{ .err = "usage: nayr workspace <name> <command>" });
}

fn runInfo(allocator: std.mem.Allocator, cwd: []const u8, writer: output.Writer) !void {
    const workspaces = try ws_discovery.discover(allocator, cwd);
    defer ws_discovery.freeDiscovered(allocator, workspaces);

    if (workspaces.len == 0) {
        writer.emit(.{ .info = "no workspaces found" });
        return;
    }

    for (workspaces) |ws| {
        const cols = &[_][]const u8{
            ws.manifest.name orelse "(unnamed)",
            ws.manifest.version orelse "0.0.0",
            ws.rel_path,
        };
        writer.emit(.{ .table_row = .{ .columns = cols } });
    }
}

fn runScriptAll(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    writer: output.Writer,
) !void {
    if (args.len == 0) {
        writer.emit(.{ .err = "usage: nayr workspaces run <script>" });
        return;
    }
    const script_name = args[0];
    const workspaces = try ws_discovery.discover(allocator, cwd);
    defer ws_discovery.freeDiscovered(allocator, workspaces);

    for (workspaces) |ws| {
        const script_cmd = ws.manifest.scripts.get(script_name) orelse continue;
        writer.emit(.{ .script_start = .{ .name = ws.manifest.name orelse ws.rel_path, .script = script_name } });
        const exit_code = platform.runScript(allocator, script_cmd, ws.path) catch 1;
        if (exit_code != 0) {
            writer.emit(.{ .warning = try std.fmt.allocPrint(
                allocator,
                "script {s} failed in {s} (exit {d})",
                .{ script_name, ws.rel_path, exit_code },
            ) });
        }
    }
}

fn runInWorkspace(
    allocator: std.mem.Allocator,
    ws_name: []const u8,
    cmd_args: []const []const u8,
    cwd: []const u8,
    _: *const Config,
    writer: output.Writer,
) !void {
    const workspaces = try ws_discovery.discover(allocator, cwd);
    defer ws_discovery.freeDiscovered(allocator, workspaces);

    for (workspaces) |ws| {
        const name = ws.manifest.name orelse continue;
        if (!std.mem.eql(u8, name, ws_name)) continue;

        if (cmd_args.len == 0) return;

        // `nayr workspace <name> run <script>`
        if (std.mem.eql(u8, cmd_args[0], "run") and cmd_args.len > 1) {
            const script_name = cmd_args[1];
            const script_cmd = ws.manifest.scripts.get(script_name) orelse {
                writer.emit(.{ .err = try std.fmt.allocPrint(allocator, "script not found: {s}", .{script_name}) });
                return;
            };
            writer.emit(.{ .script_start = .{ .name = name, .script = script_name } });
            _ = try platform.runScript(allocator, script_cmd, ws.path);
            return;
        }

        // `nayr workspace <name> <script>` — yarn compatibility: if the first
        // argument matches a script in the workspace manifest, run it directly
        // without requiring the explicit `run` prefix.  This allows
        //   yarn workspace @typr/js build
        // (stored as "build": "tsc -p tsconfig.json") to work as expected.
        if (cmd_args.len == 1) {
            if (ws.manifest.scripts.get(cmd_args[0])) |script_cmd| {
                writer.emit(.{ .script_start = .{ .name = name, .script = cmd_args[0] } });
                _ = try platform.runScript(allocator, script_cmd, ws.path);
                return;
            }
        }

        // Run an arbitrary command in the workspace directory.
        const full_cmd = try std.mem.join(allocator, " ", cmd_args);
        defer allocator.free(full_cmd);
        _ = try platform.runScript(allocator, full_cmd, ws.path);
        return;
    }

    writer.emit(.{ .err = try std.fmt.allocPrint(allocator, "workspace not found: {s}", .{ws_name}) });
}
