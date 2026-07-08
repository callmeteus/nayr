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
const build_options = @import("build_options");

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
const global_cmd = @import("global.zig");
const config_cmd = @import("config.zig");
const update_notifier = @import("../util/update_notifier.zig");

/// nayr version string - embedded from package.json at build time.
pub const VERSION = build_options.version;

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
    /// Skip background update checks and stale-version notices.
    no_update_notifier: bool = false,

    pub fn deinit(self: *const GlobalOptions, allocator: std.mem.Allocator) void {
        if (self.cwd_owned) allocator.free(self.cwd);
    }
};

/// Resolves the process working directory to an absolute path for stable joins
/// (e.g. `accessAbsolute` with `cwd` + `package.json`).
///
/// ## Parameters
/// - `allocator` - Allocator for the returned path string.
///
/// ## Returns
/// Canonical absolute cwd, or an error if neither realpath nor getcwd succeeds.
fn resolveDefaultCwd(allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.cwd().realpathAlloc(allocator, ".") catch std.process.getCwdAlloc(allocator);
}

/// Resolves a user `--cwd` value to an absolute path when possible.
///
/// ## Parameters
/// - `allocator` - Allocator for the returned path when resolution allocates.
/// - `path` - Path from argv (absolute or relative to the process cwd).
///
/// ## Returns
/// Canonical absolute path, or an error if the directory cannot be opened.
fn resolveUserCwd(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        var dir = try std.fs.openDirAbsolute(path, .{});
        defer dir.close();
        return try dir.realpathAlloc(allocator, ".");
    }

    return try std.fs.cwd().realpathAlloc(allocator, path);
}

// ============================================================================
// Entry point
// ============================================================================

/// Parses `args` and dispatches to the correct sub-command.
///
/// ## Parameters
/// - `allocator`: Main allocator for the CLI lifetime.
/// - `args`: Raw process arguments (args[0] is the binary name).
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len >= 2 and std.mem.eql(u8, args[1], "__update-check")) {
        const running_version = if (args.len >= 3) args[2] else VERSION;
        try update_notifier.UpdateNotifier.runBackgroundCheck(allocator, running_version);
        return;
    }

    if (args.len < 2) {
        var default_opts = defaultGlobalOpts(allocator);
        defer default_opts.deinit(allocator);
        maybeRunUpdateNotifier(default_opts);
        output.printBanner(default_opts.format, default_opts.silent);
        return runInstall(allocator, args, default_opts);
    }

    const global = try parseGlobalOpts(allocator, args);
    const remaining = global.remaining;
    var opts = global.opts;
    defer opts.deinit(allocator);

    if (shouldRunUpdateNotifier(remaining)) {
        maybeRunUpdateNotifier(opts);
    }

    // When only global flags were provided (no sub-command), run install.
    if (remaining.len == 0) {
        output.printBanner(opts.format, opts.silent);
        try runInstall(allocator, remaining, opts);
        return;
    }

    const cmd = remaining[0];
    const cmd_args = remaining[1..];

    // --version / --help: no banner, just print and exit.
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        const colour = output.hasTtyStderr();
        if (colour) {
            std.io.getStdOut().writer().print(
                "\x1b[1mnayr\x1b[0m \x1b[2mv{s}\x1b[0m\n",
                .{VERSION},
            ) catch {};
        } else {
            std.io.getStdOut().writer().print("nayr v{s}\n", .{VERSION}) catch {};
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printHelp();
        return;
    }

    // Print banner for all other commands.
    output.printBanner(opts.format, opts.silent);

    // Initialise the output writer.
    const fmt = opts.format;
    const writer = try output.createWriter(allocator, fmt, opts.verbose);
    defer writer.deinit();

    // Load config.
    var config = try config_loader.load(allocator, opts.cwd);
    defer config.deinit();

    if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "i")) {
        try install_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "global") or std.mem.eql(u8, cmd, "g")) {
        try global_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "add")) {
        // `nayr add --global pkg` / `nayr add -G pkg` redirect to global add.
        if (hasGlobalFlag(cmd_args)) {
            const stripped = try stripGlobalFlag(allocator, cmd_args);
            defer allocator.free(stripped);
            try global_cmd.runAdd(allocator, stripped, &config, writer);
        } else {
            try add_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
        }
    } else if (std.mem.eql(u8, cmd, "remove") or std.mem.eql(u8, cmd, "rm")) {
        if (hasGlobalFlag(cmd_args)) {
            const stripped = try stripGlobalFlag(allocator, cmd_args);
            defer allocator.free(stripped);
            try global_cmd.runRemove(allocator, stripped, &config, writer);
        } else {
            try remove_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
        }
    } else if (std.mem.eql(u8, cmd, "upgrade") or std.mem.eql(u8, cmd, "up")) {
        try upgrade_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "audit")) {
        try audit_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "link")) {
        try link_cmd.runLink(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "unlink")) {
        try link_cmd.runUnlink(allocator, cmd_args, opts.cwd, &config, writer);
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
    } else if (std.mem.eql(u8, cmd, "config")) {
        try config_cmd.run(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "cache")) {
        try runCache(allocator, cmd_args, opts.cwd, &config, writer);
    } else if (std.mem.eql(u8, cmd, "run")) {
        // `nayr run <script>` - run a script from package.json.
        try runScript(allocator, cmd_args, opts.cwd, writer);
    } else if (cmd.len > 2 and std.mem.startsWith(u8, cmd, "--")) {
        // Yarn Classic behaviour: bare flags with no command default to install.
        // e.g. `nayr --force`, `nayr --frozen-lockfile`, `nayr --no-frozen-lockfile`, `nayr --production`.
        try install_cmd.run(allocator, remaining, opts.cwd, &config, writer);
    } else {
        // Unknown command - treat as a script name (Yarn Classic behaviour:
        // `yarn build` runs the "build" script from package.json).
        // Use `remaining` (global flags already stripped) not the raw args.
        try runScript(allocator, remaining, opts.cwd, writer);
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

/// Resolves and runs a script or local binary.
///
/// Resolution order (mirrors Yarn Classic / npm):
///   1. `scripts` field in `package.json`  - run via shell with extra args appended
///   2. `node_modules/.bin/<name>`         - run as direct binary with extra args
///   3. Neither found                      - print error and exit 1
///
/// Everything after `--` (or after the script name when using `nayr run`) is
/// forwarded as extra arguments to the underlying command.
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

    // Split: script name vs extra args (everything after `--` or just the tail).
    const script_name = args[0];
    const extra_args = blk: {
        // Strip leading `--` separator if present.
        if (args.len > 1 and std.mem.eql(u8, args[1], "--")) {
            break :blk args[2..];
        }
        break :blk args[1..];
    };

    const json_util = @import("../util/json.zig");
    const manifest_path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(manifest_path);

    // --- 1. Try package.json scripts ---
    if (json_util.parseFile(allocator, manifest_path)) |manifest_val| {
        var manifest = manifest_val;
        defer manifest.deinit(allocator);
        if (manifest.scripts.get(script_name)) |cmd| {
            // Dupe the command string before freeing the manifest so the
            // platform runner gets a stable slice.
            const cmd_owned = try allocator.dupe(u8, cmd);
            defer allocator.free(cmd_owned);
            writer.emit(.{ .script_start = .{ .name = script_name, .script = cmd_owned } });
            const exit_code = try platform.runScriptWithArgs(allocator, cmd_owned, cwd, extra_args);
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        }
    } else |_| {} // no package.json or parse error - fall through

    // --- 2. Try node_modules/.bin/<name> ---
    const bin_path = try std.fs.path.join(allocator, &.{ cwd, "node_modules", ".bin", script_name });
    defer allocator.free(bin_path);

    if (std.fs.accessAbsolute(bin_path, .{})) |_| {
        writer.emit(.{ .script_start = .{ .name = script_name, .script = bin_path } });
        const exit_code = try platform.runBinary(allocator, bin_path, extra_args, cwd);
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    } else |_| {}

    // --- 3. Not found ---
    const stderr = std.io.getStdErr().writer();
    stderr.print(
        "error: Command \"{s}\" not found.\n" ++
            "       Not a script in package.json and not in node_modules/.bin/.\n",
        .{script_name},
    ) catch {};
    std.process.exit(1);
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
        } else if (std.mem.eql(u8, arg, "--no-update-notifier")) {
            opts.no_update_notifier = true;
        } else if (std.mem.eql(u8, arg, "--cwd") and i + 1 < args.len) {
            i += 1;
            // Replace the auto-detected cwd with the user-specified one.
            if (opts.cwd_owned) {
                allocator.free(opts.cwd);
            }

            if (resolveUserCwd(allocator, args[i])) |resolved| {
                opts.cwd = resolved;
                opts.cwd_owned = true;
            } else |_| {
                opts.cwd = args[i];
                opts.cwd_owned = false; // points into args slice, not owned
            }
        } else {
            // First non-global arg: everything from here is the sub-command.
            break;
        }
    }

    return ParseResult{ .opts = opts, .remaining = args[i..] };
}

fn defaultGlobalOpts(allocator: std.mem.Allocator) GlobalOptions {
    const cwd = resolveDefaultCwd(allocator) catch return .{
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

/// Returns true if args contains `--global` or `-G`.
fn hasGlobalFlag(args: []const []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--global") or std.mem.eql(u8, a, "-G")) return true;
    }
    return false;
}

/// Returns a copy of args with `--global` / `-G` removed.
fn stripGlobalFlag(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(allocator);
    for (args) |a| {
        if (!std.mem.eql(u8, a, "--global") and !std.mem.eql(u8, a, "-G")) {
            try out.append(a);
        }
    }
    return out.toOwnedSlice();
}

fn maybeRunUpdateNotifier(opts: GlobalOptions) void {
    update_notifier.UpdateNotifier.onCliStart(std.heap.page_allocator, VERSION, .{
        .silent = opts.silent,
        .no_color = opts.no_color,
        .format = opts.format,
        .disabled = opts.no_update_notifier,
    });
}

fn shouldRunUpdateNotifier(remaining: []const []const u8) bool {
    if (remaining.len == 0) return true;
    const cmd = remaining[0];
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) return false;
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return false;
    if (std.mem.eql(u8, cmd, "__update-check")) return false;
    return true;
}

fn printHelp() void {
    const w = std.io.getStdOut().writer();
    const c = output.hasTtyStderr();

    // Colour helpers - fall back to empty strings when colour is off.
    const bold = if (c) "\x1b[1m" else "";
    const dim = if (c) "\x1b[2m" else "";
    const cyan = if (c) "\x1b[36m" else "";
    const yellow = if (c) "\x1b[33m" else "";
    const green = if (c) "\x1b[32m" else "";
    const reset = if (c) "\x1b[0m" else "";

    // Header
    w.print(
        "{s}nayr{s} {s}v{s}{s}  {s}fast · lock-free · yarn-compatible{s}\n\n",
        .{ bold, reset, dim, VERSION, reset, dim, reset },
    ) catch {};

    // Usage
    w.print("{s}Usage{s}\n  nayr {s}[options]{s} {s}<command>{s} [args]\n\n", .{
        bold, reset, dim, reset, cyan, reset,
    }) catch {};

    // Commands section
    w.print("{s}Commands{s}\n", .{ bold, reset }) catch {};

    const Cmd = struct { name: []const u8, desc: []const u8 };
    const cmds = [_]Cmd{
        .{ .name = "install", .desc = "Install all dependencies" },
        .{ .name = "add <pkg...>", .desc = "Add package(s) to package.json" },
        .{ .name = "remove <pkg...>", .desc = "Remove package(s)" },
        .{ .name = "upgrade [pkg...]", .desc = "Upgrade package(s)" },
        .{ .name = "run <script>", .desc = "Run a package.json script" },
        .{ .name = "link", .desc = "Register current package globally" },
        .{ .name = "link <name>", .desc = "Use a registered global package locally" },
        .{ .name = "unlink [name]", .desc = "Remove a global registration or local link" },
        .{ .name = "autolink", .desc = "Auto-link all registered packages" },
        .{ .name = "audit", .desc = "Run security audit" },
        .{ .name = "why <pkg>", .desc = "Explain why a package is installed" },
        .{ .name = "licenses list", .desc = "List all package licenses" },
        .{ .name = "workspace <w> <cmd>", .desc = "Run a command in a specific workspace" },
        .{ .name = "workspaces info", .desc = "List all workspaces" },
        .{ .name = "registry sync", .desc = "Sync private registry scopes to .npmrc" },
        .{ .name = "login", .desc = "Authenticate against registry/registries" },
        .{ .name = "logout", .desc = "Remove stored credentials" },
        .{ .name = "publish", .desc = "Publish the current package" },
        .{ .name = "pack", .desc = "Create a tarball without publishing" },
        .{ .name = "cache list", .desc = "List cached packages" },
        .{ .name = "cache clean", .desc = "Remove all cached packages" },
        .{ .name = "global add <pkg...>", .desc = "Install packages globally" },
        .{ .name = "global remove <pkg>", .desc = "Remove a global package" },
        .{ .name = "global list", .desc = "List globally installed packages" },
        .{ .name = "global bin", .desc = "Print the global binary directory" },
        .{ .name = "global upgrade", .desc = "Upgrade all global packages" },
    };
    for (cmds) |cmd| {
        w.print("  {s}{s:<26}{s}{s}{s}{s}\n", .{
            green, cmd.name, reset, dim, cmd.desc, reset,
        }) catch {};
    }

    // Options section
    w.print("\n{s}Options{s}\n", .{ bold, reset }) catch {};

    const Opt = struct { flag: []const u8, desc: []const u8 };
    const opts_list = [_]Opt{
        .{ .flag = "--format=tui|text|json", .desc = "Output format (default: tui when TTY)" },
        .{ .flag = "--verbose  / -v", .desc = "Verbose output" },
        .{ .flag = "--silent   / -s", .desc = "Suppress all output except errors" },
        .{ .flag = "--no-color", .desc = "Disable ANSI colours" },
        .{ .flag = "--cwd <path>", .desc = "Set working directory" },
        .{ .flag = "--global   / -G", .desc = "Apply to global packages (add/remove)" },
        .{ .flag = "--version", .desc = "Print version and exit" },
        .{ .flag = "--help     / -h", .desc = "Print this help" },
    };
    for (opts_list) |opt| {
        w.print("  {s}{s:<28}{s}{s}{s}{s}\n", .{
            yellow, opt.flag, reset, dim, opt.desc, reset,
        }) catch {};
    }

    w.print("\n", .{}) catch {};
}
