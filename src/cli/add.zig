//! `nayr add` Command
//!
//! Adds one or more packages to `package.json` and runs install.

const std = @import("std");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const install_cmd = @import("install.zig");
const Config = config_types.Config;

// ============================================================================
// Add options
// ============================================================================

pub const AddOptions = struct {
    /// Install as devDependency.
    dev: bool = false,
    /// Install as peerDependency.
    peer: bool = false,
    /// Install as optionalDependency.
    optional: bool = false,
    /// Save exact version (no ^ prefix).
    exact: bool = false,
    /// Save with ~ prefix.
    tilde: bool = false,
};

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
    var opts = AddOptions{};
    var packages = std.ArrayList([]const u8).init(allocator);
    defer packages.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dev") or std.mem.eql(u8, arg, "-D")) {
            opts.dev = true;
        } else if (std.mem.eql(u8, arg, "--peer") or std.mem.eql(u8, arg, "-P")) {
            opts.peer = true;
        } else if (std.mem.eql(u8, arg, "--optional") or std.mem.eql(u8, arg, "-O")) {
            opts.optional = true;
        } else if (std.mem.eql(u8, arg, "--exact") or std.mem.eql(u8, arg, "-E")) {
            opts.exact = true;
        } else if (std.mem.eql(u8, arg, "--tilde") or std.mem.eql(u8, arg, "-T")) {
            opts.tilde = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try packages.append(arg);
        }
    }

    if (packages.items.len == 0) {
        writer.emit(.{ .err = "nayr add: no packages specified" });
        return error.NoPackagesSpecified;
    }

    // Read + modify package.json.
    const pkg_json_path = try std.fs.path.join(allocator, &.{ cwd, "package.json" });
    defer allocator.free(pkg_json_path);

    const pkg_json_raw = blk: {
        const f = try std.fs.openFileAbsolute(pkg_json_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 4 * 1024 * 1024);
    };
    defer allocator.free(pkg_json_raw);

    // Parse into a mutable JSON value so we can add the dep entries.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, pkg_json_raw, .{});
    defer parsed.deinit();

    const dep_key: []const u8 = if (opts.dev)
        "devDependencies"
    else if (opts.peer)
        "peerDependencies"
    else if (opts.optional)
        "optionalDependencies"
    else
        "dependencies";

    // All strings inserted into the JSON tree must use the parsed arena so
    // that parsed.deinit() frees them correctly (it only frees its own arena).
    const ja = parsed.arena.allocator();

    // Arena for short-lived per-iteration strings (writer messages).
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();
    const la = loop_arena.allocator();

    for (packages.items) |pkg_spec| {
        _ = loop_arena.reset(.retain_capacity);

        // Parse `name@version` or `name`.
        // For git/URL specs (e.g. git+https://...) there is no `@` separator,
        // so the whole spec is treated as the name and version defaults to "latest".
        const at = std.mem.lastIndexOfScalar(u8, pkg_spec, '@') orelse pkg_spec.len;
        const pkg_name = if (at > 0 and pkg_spec[0] != '@') pkg_spec[0..at] else blk: {
            // Scoped package: `@scope/name@version`
            const second_at = std.mem.indexOfScalarPos(u8, pkg_spec, 1, '@') orelse break :blk pkg_spec;
            break :blk pkg_spec[0..second_at];
        };
        const requested_ver = if (at < pkg_spec.len) pkg_spec[at + 1 ..] else "latest";

        // Build the range string.
        const prefix = if (opts.exact)
            ""
        else if (opts.tilde)
            "~"
        else
            config.save_prefix;

        // range goes into the JSON tree - use json arena so parsed.deinit() frees it.
        const range: []const u8 = if (std.mem.eql(u8, requested_ver, "latest"))
            try std.fmt.allocPrint(ja, "{s}*", .{prefix})
        else
            try std.fmt.allocPrint(ja, "{s}{s}", .{ prefix, requested_ver });

        // Add to the parsed JSON object.
        if (parsed.value.object.getPtr(dep_key)) |deps_val| {
            if (deps_val.* == .object) {
                try deps_val.object.put(try ja.dupe(u8, pkg_name), .{ .string = range });
            }
        } else {
            var new_deps = std.json.ObjectMap.init(ja);
            try new_deps.put(try ja.dupe(u8, pkg_name), .{ .string = range });
            try parsed.value.object.put(try ja.dupe(u8, dep_key), .{ .object = new_deps });
        }

        writer.emit(.{ .info = try std.fmt.allocPrint(la, "added {s}@{s} to {s}", .{ pkg_name, range, dep_key }) });
    }

    // Write updated package.json atomically.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{pkg_json_path});
    defer allocator.free(tmp_path);
    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        try std.json.stringify(parsed.value, .{ .whitespace = .indent_2 }, f.writer());
        try f.writeAll("\n");
    }
    try std.fs.renameAbsolute(tmp_path, pkg_json_path);

    // Run install to apply the changes.
    try install_cmd.run(allocator, &.{}, cwd, config, writer);
}
