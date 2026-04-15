//! `nayr global` Command
//!
//! Manages globally installed packages and their binaries.
//! Global packages are stored in `~/.nayr/global/` and their binaries are
//! symlinked into `~/.nayr/bin/`, which the user should add to PATH.
//!
//! Sub-commands:
//!   add <pkg...>      Install packages globally
//!   remove <pkg...>   Remove global packages
//!   list              List installed global packages
//!   bin               Print the global binary directory
//!   upgrade [pkg...]  Upgrade global package(s)

const std = @import("std");
const output = @import("../util/output.zig");
const platform = @import("../util/platform.zig");
const config_types = @import("../config/types.zig");
const install_cmd = @import("install.zig");
const fs_util = @import("../util/fs.zig");
const Config = config_types.Config;

// ============================================================================
// Entry point
// ============================================================================

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    _: []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    const sub = if (args.len > 0) args[0] else "list";
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, sub, "add")) {
        try runAdd(allocator, sub_args, config, writer);
    } else if (std.mem.eql(u8, sub, "remove") or std.mem.eql(u8, sub, "rm")) {
        try runRemove(allocator, sub_args, config, writer);
    } else if (std.mem.eql(u8, sub, "upgrade") or std.mem.eql(u8, sub, "up")) {
        try runUpgrade(allocator, sub_args, config, writer);
    } else if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "ls")) {
        try runList(allocator, writer);
    } else if (std.mem.eql(u8, sub, "bin")) {
        try runBin(allocator, writer);
    } else if (std.mem.eql(u8, sub, "dir")) {
        const global_dir = try platform.getGlobalDir(allocator);
        defer allocator.free(global_dir);
        const stdout = std.io.getStdOut().writer();
        try stdout.print("{s}\n", .{global_dir});
    } else {
        writer.emit(.{ .err = "usage: nayr global <add|remove|list|bin|dir|upgrade>" });
        return error.UnknownSubCommand;
    }
}

// ============================================================================
// `nayr global add <pkg...>`
// ============================================================================

pub fn runAdd(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    // Collect package specs, strip flags.
    var packages = std.ArrayList([]const u8).init(allocator);
    defer packages.deinit();
    var exact = false;
    var dev = false;
    var optional = false;
    var peer = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--exact") or std.mem.eql(u8, arg, "-E")) {
            exact = true;
        } else if (std.mem.eql(u8, arg, "--dev") or std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "-d")) {
            dev = true;
        } else if (std.mem.eql(u8, arg, "--optional") or std.mem.eql(u8, arg, "-O") or std.mem.eql(u8, arg, "-o")) {
            optional = true;
        } else if (std.mem.eql(u8, arg, "--peer") or std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "-p")) {
            peer = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try packages.append(arg);
        }
    }

    if (packages.items.len == 0) {
        writer.emit(.{ .err = "nayr global add: no packages specified" });
        return error.NoPackagesSpecified;
    }

    const global_dir = try platform.getGlobalDir(allocator);
    defer allocator.free(global_dir);

    try ensureGlobalDir(allocator, global_dir);

    // Update ~/.nayr/global/package.json with the new deps.
    const pkg_path = try std.fs.path.join(allocator, &.{ global_dir, "package.json" });
    defer allocator.free(pkg_path);

    const raw = blk: {
        const f = std.fs.openFileAbsolute(pkg_path, .{}) catch break :blk null;
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 4 * 1024 * 1024);
    };
    defer if (raw) |r| allocator.free(r);

    var parsed = if (raw) |r|
        try std.json.parseFromSlice(std.json.Value, allocator, r, .{})
    else blk: {
        const empty = "{\"name\":\"nayr-global\",\"version\":\"1.0.0\",\"private\":true,\"dependencies\":{}}";
        break :blk try std.json.parseFromSlice(std.json.Value, allocator, empty, .{});
    };
    defer parsed.deinit();

    // All strings inserted into the JSON tree must use the parsed arena so
    // that parsed.deinit() frees them correctly (it only frees its own arena).
    const ja = parsed.arena.allocator();

    // Arena for short-lived per-iteration strings (writer messages, etc.).
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();
    const la = loop_arena.allocator();

    const dep_key: []const u8 = if (dev)
        "devDependencies"
    else if (optional)
        "optionalDependencies"
    else if (peer)
        "peerDependencies"
    else
        "dependencies";

    for (packages.items) |spec| {
        _ = loop_arena.reset(.retain_capacity);
        const name, const ver = splitSpec(spec);
        const prefix: []const u8 = if (exact) "" else config.save_prefix;

        // range goes into the JSON tree — use json arena.
        const range: []const u8 = if (std.mem.eql(u8, ver, "latest"))
            try ja.dupe(u8, "*")
        else
            try std.fmt.allocPrint(ja, "{s}{s}", .{ prefix, ver });

        writer.emit(.{ .info = try std.fmt.allocPrint(
            la, "Adding {s}@{s} to global {s}", .{ name, range, dep_key },
        ) });

        // Ensure the target key exists, then insert. Both key and value use
        // the json arena so parsed.deinit() cleans them up.
        if (parsed.value.object.getPtr(dep_key)) |deps| {
            try deps.object.put(try ja.dupe(u8, name), .{ .string = range });
        } else {
            var new_obj = std.json.ObjectMap.init(ja);
            try new_obj.put(try ja.dupe(u8, name), .{ .string = range });
            try parsed.value.object.put(try ja.dupe(u8, dep_key), .{ .object = new_obj });
        }
    }

    try writePackageJson(allocator, pkg_path, parsed.value);

    // Run install in the global dir.
    try install_cmd.run(allocator, &.{}, global_dir, config, writer);

    // Expose binaries.
    const linked = try syncGlobalBins(allocator, global_dir, writer);
    try checkPath(allocator, writer, linked);
}

// ============================================================================
// `nayr global remove <pkg...>`
// ============================================================================

pub fn runRemove(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    if (args.len == 0) {
        writer.emit(.{ .err = "nayr global remove: no packages specified" });
        return error.NoPackagesSpecified;
    }

    const global_dir = try platform.getGlobalDir(allocator);
    defer allocator.free(global_dir);

    const pkg_path = try std.fs.path.join(allocator, &.{ global_dir, "package.json" });
    defer allocator.free(pkg_path);

    const raw = blk: {
        const f = std.fs.openFileAbsolute(pkg_path, .{}) catch {
            writer.emit(.{ .warning = "no global packages installed" });
            return;
        };
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 4 * 1024 * 1024);
    };
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    for (args) |pkg_name| {
        if (std.mem.startsWith(u8, pkg_name, "-")) continue;
        // Remove from all buckets so the user doesn't have to remember
        // which flag was used during install.
        for (&[_][]const u8{ "dependencies", "devDependencies", "optionalDependencies", "peerDependencies" }) |key| {
            if (parsed.value.object.getPtr(key)) |deps| {
                _ = deps.object.orderedRemove(pkg_name);
            }
        }
        writer.emit(.{ .info = try std.fmt.allocPrint(
            allocator, "Removing {s} from global packages", .{pkg_name},
        ) });
    }

    try writePackageJson(allocator, pkg_path, parsed.value);
    try install_cmd.run(allocator, &.{}, global_dir, config, writer);
    _ = try syncGlobalBins(allocator, global_dir, writer);
}

// ============================================================================
// `nayr global upgrade [pkg...]`
// ============================================================================

fn runUpgrade(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    const global_dir = try platform.getGlobalDir(allocator);
    defer allocator.free(global_dir);

    // `--force` on upgrade re-resolves everything to latest.
    const install_args: []const []const u8 = if (args.len == 0)
        &.{"--force"}
    else
        &.{};

    try install_cmd.run(allocator, install_args, global_dir, config, writer);
    _ = try syncGlobalBins(allocator, global_dir, writer);
}

// ============================================================================
// `nayr global list`
// ============================================================================

fn runList(allocator: std.mem.Allocator, writer: output.Writer) !void {
    const global_dir = try platform.getGlobalDir(allocator);
    defer allocator.free(global_dir);

    const pkg_path = try std.fs.path.join(allocator, &.{ global_dir, "package.json" });
    defer allocator.free(pkg_path);

    const raw = blk: {
        const f = std.fs.openFileAbsolute(pkg_path, .{}) catch {
            writer.emit(.{ .info = "No global packages installed." });
            return;
        };
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 4 * 1024 * 1024);
    };
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const total: usize = blk: {
        var n: usize = 0;
        if (parsed.value.object.get("dependencies")) |d| n += d.object.count();
        if (parsed.value.object.get("devDependencies")) |d| n += d.object.count();
        if (parsed.value.object.get("optionalDependencies")) |d| n += d.object.count();
        if (parsed.value.object.get("peerDependencies")) |d| n += d.object.count();
        break :blk n;
    };
    if (total == 0) {
        writer.emit(.{ .info = "No global packages installed." });
        return;
    }

    // Show resolved versions from node_modules if available, else fall back
    // to the range stored in package.json.
    // Use an arena so all per-entry allocations are freed together at the end.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sections = [_][]const u8{ "dependencies", "devDependencies", "optionalDependencies", "peerDependencies" };
    for (sections) |section| {
        const section_deps = parsed.value.object.get(section) orelse continue;
        var it = section_deps.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const range = entry.value_ptr.string;

            const version = blk: {
                const nm_pkg = try std.fs.path.join(
                    a, &.{ global_dir, "node_modules", name, "package.json" },
                );
                const f = std.fs.openFileAbsolute(nm_pkg, .{}) catch break :blk range;
                defer f.close();
                const nm_raw = f.readToEndAlloc(a, 256 * 1024) catch break :blk range;
                const nm_parsed = std.json.parseFromSlice(std.json.Value, a, nm_raw, .{}) catch break :blk range;
                const v = nm_parsed.value.object.get("version") orelse break :blk range;
                break :blk v.string;
            };

            const suffix: []const u8 = if (std.mem.eql(u8, section, "devDependencies"))
                " (dev)"
            else if (std.mem.eql(u8, section, "optionalDependencies"))
                " (optional)"
            else if (std.mem.eql(u8, section, "peerDependencies"))
                " (peer)"
            else
                "";
            const line = try std.fmt.allocPrint(a, "{s}@{s}{s}", .{ name, version, suffix });
            writer.emit(.{ .info = line });
        }
    }
}

// ============================================================================
// `nayr global bin`
// ============================================================================

fn runBin(allocator: std.mem.Allocator, writer: output.Writer) !void {
    const bin_dir = try platform.getGlobalBinDir(allocator);
    defer allocator.free(bin_dir);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{bin_dir});
    _ = writer;
}

// ============================================================================
// Helpers
// ============================================================================

/// Ensures `~/.nayr/global/` exists with a minimal `package.json`.
fn ensureGlobalDir(allocator: std.mem.Allocator, global_dir: []const u8) !void {
    try fs_util.mkdirAllRecursive(allocator, global_dir);

    const pkg_path = try std.fs.path.join(allocator, &.{ global_dir, "package.json" });
    defer allocator.free(pkg_path);

    std.fs.accessAbsolute(pkg_path, .{}) catch {
        const f = try std.fs.createFileAbsolute(pkg_path, .{});
        defer f.close();
        try f.writeAll(
            \\{
            \\  "name": "nayr-global",
            \\  "version": "1.0.0",
            \\  "private": true,
            \\  "dependencies": {}
            \\}
            \\
        );
    };
}

/// Writes a JSON value to a file atomically.
fn writePackageJson(
    allocator: std.mem.Allocator,
    path: []const u8,
    value: std.json.Value,
) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    {
        const f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true });
        defer f.close();
        try std.json.stringify(value, .{ .whitespace = .indent_2 }, f.writer());
        try f.writeAll("\n");
    }
    try std.fs.renameAbsolute(tmp, path);
}

/// Scans `~/.nayr/global/node_modules/.bin/` and creates matching symlinks
/// in `~/.nayr/bin/` so the binaries are accessible from PATH.
///
/// Returns true if at least one binary was linked.
fn syncGlobalBins(
    allocator: std.mem.Allocator,
    global_dir: []const u8,
    writer: output.Writer,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bin_src = try std.fs.path.join(
        a, &.{ global_dir, "node_modules", ".bin" },
    );
    const bin_dst = try platform.getGlobalBinDir(a);

    // Rebuild bin_dst from scratch so stale stubs from removed packages are gone.
    std.fs.deleteTreeAbsolute(bin_dst) catch {};
    try fs_util.mkdirAllRecursive(allocator, bin_dst);

    var src_dir = std.fs.openDirAbsolute(bin_src, .{ .iterate = true }) catch return false;
    defer src_dir.close();

    var linked = false;
    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .sym_link and entry.kind != .file) continue;

        const src_path = try std.fs.path.join(a, &.{ bin_src, entry.name });

        // Skip broken symlinks - the package they point to was removed.
        std.fs.accessAbsolute(src_path, .{}) catch continue;

        const dst_path = try std.fs.path.join(a, &.{ bin_dst, entry.name });
        platform.symlinkOrJunction(src_path, dst_path) catch continue;
        linked = true;
        writer.emit(.{ .info = try std.fmt.allocPrint(a, "linked binary: {s}", .{entry.name}) });
    }
    return linked;
}

/// Ensures `~/.nayr/bin` is in PATH.
///
/// If already present in the current session's PATH, nothing happens.
/// Otherwise, the export line is appended to the user's shell rc file
/// (~/.bashrc, ~/.zshrc, or ~/.profile as fallback) so all future sessions
/// pick it up automatically.  A one-line notice is printed.
fn checkPath(
    allocator: std.mem.Allocator,
    writer: output.Writer,
    has_bins: bool,
) !void {
    if (!has_bins) return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bin_dir = try platform.getGlobalBinDir(a);

    // Already in the current session's PATH - nothing to do.
    if (std.process.getEnvVarOwned(a, "PATH")) |path_env| {
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |seg| {
            if (std.mem.eql(u8, seg, bin_dir)) return;
        }
    } else |_| {}

    // Not in the current session's PATH - check the rc file.
    const rc_path = resolveRcFile(a) catch null;
    const marker = try std.fmt.allocPrint(a, "PATH=\"{s}", .{bin_dir});

    if (rc_path) |rc| {
        const in_rc: bool = blk: {
            const f = std.fs.openFileAbsolute(rc, .{}) catch break :blk false;
            defer f.close();
            const contents = f.readToEndAlloc(a, 256 * 1024) catch break :blk false;
            break :blk std.mem.indexOf(u8, contents, marker) != null;
        };

        if (in_rc) {
            // Already in the rc file but not yet active - just remind once.
            writer.emit(.{ .info = try std.fmt.allocPrint(
                a, "Run `source {s}` or open a new terminal to use global binaries.", .{rc},
            ) });
        } else {
            // Append the export line.
            const export_line = try std.fmt.allocPrint(
                a, "\nexport PATH=\"{s}:$PATH\"\n", .{bin_dir},
            );
            const f = std.fs.openFileAbsolute(rc, .{ .mode = .read_write }) catch
                std.fs.createFileAbsolute(rc, .{}) catch {
                    fallbackPathWarning(writer, a, bin_dir);
                    return;
                };
            defer f.close();
            try f.seekFromEnd(0);
            try f.writeAll(export_line);

            writer.emit(.{ .info = try std.fmt.allocPrint(
                a, "Added {s} to PATH in {s}", .{ bin_dir, rc },
            ) });
            writer.emit(.{ .info = try std.fmt.allocPrint(
                a, "Run `source {s}` or open a new terminal to apply.", .{rc},
            ) });
        }
    } else {
        fallbackPathWarning(writer, a, bin_dir);
    }
}

/// Returns the path to the user's shell rc file based on $SHELL.
fn resolveRcFile(a: std.mem.Allocator) ![]const u8 {
    const home = try platform.getHomeDir(a);
    const shell = std.process.getEnvVarOwned(a, "SHELL") catch "";
    if (std.mem.endsWith(u8, shell, "zsh")) {
        return std.fs.path.join(a, &.{ home, ".zshrc" });
    }
    if (std.mem.endsWith(u8, shell, "fish")) {
        return std.fs.path.join(a, &.{ home, ".config", "fish", "config.fish" });
    }
    // bash or unknown - use .bashrc, fall back to .profile.
    const bashrc = try std.fs.path.join(a, &.{ home, ".bashrc" });
    std.fs.accessAbsolute(bashrc, .{}) catch {
        return std.fs.path.join(a, &.{ home, ".profile" });
    };
    return bashrc;
}

fn fallbackPathWarning(writer: output.Writer, a: std.mem.Allocator, bin_dir: []const u8) void {
    writer.emit(.{ .warning = std.fmt.allocPrint(
        a,
        "Add {s} to your PATH manually:\n       export PATH=\"{s}:$PATH\"",
        .{ bin_dir, bin_dir },
    ) catch bin_dir });
}

/// Splits `name@version` or `@scope/name@version` into (name, version).
/// Returns ("name", "latest") when no version is specified.
fn splitSpec(spec: []const u8) struct { []const u8, []const u8 } {
    // Scoped package: starts with @, second @ is the version separator.
    if (spec.len > 0 and spec[0] == '@') {
        const at2 = std.mem.indexOfScalarPos(u8, spec, 1, '@') orelse return .{ spec, "latest" };
        return .{ spec[0..at2], spec[at2 + 1 ..] };
    }
    const at = std.mem.indexOfScalar(u8, spec, '@') orelse return .{ spec, "latest" };
    return .{ spec[0..at], spec[at + 1 ..] };
}
