//! CLI Root - Command Dispatcher
//!
//! Parses global flags and routes to the appropriate sub-command handler.
//! All output passes through the `Writer` selected by `--format`.
//!
//! Global flags (accepted before any sub-command):
//!   --format=tui|text|json   Output format (default: tui when TTY, text otherwise)
//!   --verbose / -v           Verbose output
//!   --silent / -s            Suppress all output except errors
//!   --no-color               Disable ANSI colour codes
//!   --cwd <path>             Override the working directory
//!   --version                Print nayr version and exit
//!   --help / -h              Print usage and exit

const std = @import("std");
const output = @import("../util/output.zig");
const platform = @import("../util/platform.zig");
const config_loader = @import("../config/loader.zig");

const install_cmd = @import("install.zig");
const add_cmd = @import("add.zig");
const remove_cmd = @import("remove.zig");
const upgrade_cmd = @import("upgrade.zig");
const audit_cmd = @import("audit.zig");
const link_cmd = @import("link.zig");
const why_cmd = @import("why.zig");
const licenses_cmd = @import("licenses.zig");
const workspace_cmd = @import("workspace.zig");
const registry_cmd = @import("registry_cmd.zig");
const login_cmd = @import("login.zig");
const publish_cmd = @import("publish.zig");

/// nayr version string.
pub const VERSION = "0.1.0";

// ============================================================================
// Global options
// ============================================================================

/// Options parsed from the global (pre-command) argument section.
pub const GlobalOptions = struct {
    format: output.Format,
    verbose: bool,
    silent: bool,
    no_color: bool,
    cwd: []const u8,
    /// True when `cwd` was allocated by this struct and must be freed.
    cwd_owned: bool = false,

    pub fn deinit(self: *const GlobalOptions, allocator: std.mem.Allocator) void {
        if (self.cwd_owned) allocator.free(self.cwd);
    }
};

// ============================================================================
// Entry point
// ============================================================================

/// Parses `args` and dispatches to the correct sub-command.
///
/// ## Parameters
/// - `allocator`: Main allocator for the CLI lifetime.
/// - `args`: Raw process arguments (args[0] is the binary name).
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        var default_opts = defaultGlobalOpts(allocator);
        defer default_opts.deinit(allocator);
        return runInstall(allocator, args, default_opts);
    }

    const global = try parseGlobalOpts(allocator, args);
    const remaining = global.remaining;
    var opts = global.opts;
    defer opts.deinit(allocator);

    // Version flag.
    if (remaining.len == 0) {
        try runInstall(allocator, remaining, opts);
        return;
    }

    const cmd = remaining[0];
    const cmd_args = remaining[1..];

    // Initialise the output writer.
    const fmt = opts.format;
    const writer = try output.createWriter(allocator, fmt, opts.verbose);
    defer writer.deinit();

    // Load config.
    var config = try config_loader.load(allocator, opts.cwd);
    defer config.deinit();

    if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "i")) {
        try install_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "add")) {
        try add_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "remove") or std.mem.eql(u8, cmd, "rm")) {
        try remove_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "upgrade") or std.mem.eql(u8, cmd, "up")) {
        try upgrade_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "audit")) {
        try audit_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "link")) {
        try link_cmd.runLink(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "unlink")) {
        try link_cmd.runUnlink(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "mklink")) {
        try link_cmd.runMklink(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "autolink")) {
        try link_cmd.runAutolink(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "why")) {
        try why_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "licenses")) {
        try licenses_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "workspace") or std.mem.eql(u8, cmd, "workspaces")) {
        try workspace_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "registry")) {
        try registry_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "login")) {
        try login_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "logout")) {
        try login_cmd.runLogout(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "publish")) {
        try publish_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "pack")) {
        try publish_cmd.runPack(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "cache")) {
        try runCache(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        try std.io.getStdOut().writer().print("nayr {s}\n", .{VERSION});
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printHelp();
    } else if (std.mem.eql(u8, cmd, "run")) {
        // `nayr run <script>` - run a script from package.json.
        try runScript(allocator, cmd_args, opts.cwd, writer);
    } else {
        // Unknown command - treat as a script name (Yarn Classic behaviour:
        // `yarn build` runs the "build" script from package.json).
        const script_args = args[1..];
        try runScript(allocator, script_args, opts.cwd, writer);
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn runInstall(allocator: std.mem.Allocator, _: []const []const u8, opts: GlobalOptions) !void {
    const writer = try output.createWriter(allocator, opts.format, opts.verbose);
    defer writer.deinit();
    var config = try config_loader.load(allocator, opts.cwd);
    defer config.deinit();
    try install_cmd.run(allocator, &.{}, opts.cwd, &config, writer);
}

fn runCache(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    _: anytype,
    writer: output.Writer,
) !void {
    _ = cwd;
    const platform_mod = @import("../util/platform.zig");
    const cache_dir = try platform_mod.getCacheDir(allocator);
    defer allocator.free(cache_dir);

    const sub = if (args.len > 0) args[0] else "list";

    if (std.mem.eql(u8, sub, "list")) {
        var cache = try @import("../core/cache.zig").Cache.init(allocator, cache_dir);
        defer cache.deinit();
        const entries = try cache.list();
        for (entries) |e| writer.emit(.{ .info = e });
    } else if (std.mem.eql(u8, sub, "clean")) {
        var cache = try @import("../core/cache.zig").Cache.init(allocator, cache_dir);
        defer cache.deinit();
        try cache.clean();
        writer.emit(.{ .info = "cache cleared" });
    } else {
        writer.emit(.{ .err = "usage: nayr cache [list|clean]" });
    }
}

fn runScript(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    writer: output.Writer,
) !void {
    if (args.len == 0) {
        printHelp();
        return;
    }
    const script_name = args[0];
    const json_util = @import("../util/json.zig");
    const manifest_path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(manifest_path);
    const manifest = try json_util.parseFile(allocator, manifest_path);
    const cmd = manifest.scripts.get(script_name) orelse {
        writer.emit(.{ .err = try std.fmt.allocPrint(allocator, "script not found: {s}", .{script_name}) });
        return;
    };
    writer.emit(.{ .script_start = .{ .name = script_name, .script = cmd } });
    const exit_code = try platform.runScript(allocator, cmd, cwd);
    if (exit_code != 0) {
        return error.ScriptFailed;
    }
}

// ============================================================================
// Global option parsing
// ============================================================================

const ParseResult = struct {
    opts: GlobalOptions,
    remaining: []const []const u8,
};

fn parseGlobalOpts(allocator: std.mem.Allocator, args: []const []const u8) !ParseResult {
    var opts = defaultGlobalOpts(allocator);
    var i: usize = 1; // skip binary name

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--format=")) {
            opts.format = output.Format.parse(arg["--format=".len..]) catch opts.format;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--silent") or std.mem.eql(u8, arg, "-s")) {
            opts.silent = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, arg, "--cwd") and i + 1 < args.len) {
            i += 1;
            // Replace the auto-detected cwd with the user-specified one.
            if (opts.cwd_owned) allocator.free(opts.cwd);
            opts.cwd = args[i];
            opts.cwd_owned = false; // points into args slice, not owned
        } else {
            // First non-global arg: everything from here is the sub-command.
            break;
        }
    }

    return ParseResult{ .opts = opts, .remaining = args[i..] };
}

fn defaultGlobalOpts(allocator: std.mem.Allocator) GlobalOptions {
    const cwd = std.process.getCwdAlloc(allocator) catch return .{
        .format = output.Format.autoDetect(),
        .verbose = false,
        .silent = false,
        .no_color = false,
        .cwd = ".",
        .cwd_owned = false,
    };
    return .{
        .format = output.Format.autoDetect(),
        .verbose = false,
        .silent = false,
        .no_color = false,
        .cwd = cwd,
        .cwd_owned = true,
    };
}

fn printHelp() void {
    const help =
        \\nayr - fast Node.js package manager (Yarn Classic compatible)
        \\
        \\Usage: nayr [options] <command> [args]
        \\
        \\Commands:
        \\  install / i          Install all dependencies
        \\  add <pkg...>         Add package(s) to package.json
        \\  remove / rm <pkg...> Remove package(s)
        \\  upgrade [pkg...]     Upgrade package(s)
        \\  link [name]          Register or use a local package link
        \\  unlink [name]        Remove a local package link
        \\  mklink [glob]        Register multiple packages via glob
        \\  autolink             Auto-link all registered packages
        \\  audit                Run security audit
        \\  why <pkg>            Explain why a package is installed
        \\  licenses list        List all package licenses
        \\  workspace <ws> <cmd> Run a command in a specific workspace
        \\  workspaces info      List all workspaces
        \\  registry sync        Sync private registry scopes to .npmrc
        \\  login                Authenticate against registry/registries
        \\  logout               Remove stored credentials
        \\  publish              Publish the current package
        \\  pack                 Create a tarball without publishing
        \\  run <script>         Run a package.json script
        \\  cache list           List cached packages
        \\  cache clean          Remove all cached packages
        \\
        \\Global options:
        \\  --format=tui|text|json  Output format (default: tui when TTY)
        \\  --verbose / -v          Verbose output
        \\  --silent / -s           Suppress all output except errors
        \\  --no-color              Disable ANSI colours
        \\  --cwd <path>            Set working directory
        \\  --version               Print version and exit
        \\  --help / -h             Print this help
        \\
    ;
    std.io.getStdOut().writer().writeAll(help) catch {};
}
