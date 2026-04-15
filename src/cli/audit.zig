//! `nayr audit` Command
//!
//! Checks installed packages for known security vulnerabilities via the
//! npm audit bulk advisory API:
//!   POST /-/npm/v1/security/advisories/bulk
//!
//! Request body: `{ "package-name": ["installed-version"], ... }`
//! Response:     `{ "package-name": [{ "id", "severity", "title", ... }], ... }`

const std = @import("std");
const output = @import("../util/output.zig");
const config_types = @import("../config/types.zig");
const Config = config_types.Config;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    config: *const Config,
    writer: output.Writer,
) !void {
    var min_level: []const u8 = "info";

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--level=")) {
            min_level = arg["--level=".len..];
        }
    }

    // Build the request body from installed packages.
    const body = buildRequestBody(allocator, cwd) catch |err| blk: {
        if (err == error.FileNotFound or err == error.NotDir) {
            writer.emit(.{ .err = "node_modules not found - run nayr install first" });
            return;
        }
        const msg = try std.fmt.allocPrint(
            allocator,
            "audit: could not read node_modules ({s})",
            .{@errorName(err)},
        );
        defer allocator.free(msg);
        writer.emit(.{ .warning = msg });
        break :blk try allocator.dupe(u8, "{}");
    };
    defer allocator.free(body);

    // If we found no packages, nothing to audit.
    if (std.mem.eql(u8, body, "{}")) {
        writer.emit(.{ .info = "audit: no packages to audit" });
        return;
    }

    const registry = config.registry;
    const audit_url = try std.fmt.allocPrint(
        allocator,
        "{s}/-/npm/v1/security/advisories/bulk",
        .{std.mem.trimRight(u8, registry, "/")},
    );
    defer allocator.free(audit_url);

    const resp_body = curlPost(allocator, audit_url, body, config.getAuthToken(audit_url)) catch {
        writer.emit(.{ .warning = "audit: could not reach registry" });
        return;
    };
    defer allocator.free(resp_body);

    try reportVulnerabilities(allocator, resp_body, min_level, writer);
}

// ----------------------------------------------------------------------------
// Request body builder
// ----------------------------------------------------------------------------

/// Scans `node_modules` and builds the JSON body for the bulk advisory API.
///
/// Format: `{ "lodash": ["4.17.21"], "ms": ["2.1.3"], ... }`
fn buildRequestBody(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const node_modules = try std.fs.path.join(allocator, &.{ cwd, "node_modules" });
    defer allocator.free(node_modules);

    var dir = try std.fs.openDirAbsolute(node_modules, .{ .iterate = true });
    defer dir.close();

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();

    var first = true;
    try w.writeByte('{');

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;

        if (entry.name[0] == '@') {
            // Recurse into scoped directory.
            const scope_path = try std.fs.path.join(allocator, &.{ node_modules, entry.name });
            defer allocator.free(scope_path);
            first = try collectScoped(allocator, scope_path, entry.name, w, first);
        } else {
            const version = readVersion(allocator, node_modules, entry.name) catch continue;
            defer allocator.free(version);
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("\"{s}\":[\"{s}\"]", .{ entry.name, version });
        }
    }

    try w.writeByte('}');
    return buf.toOwnedSlice();
}

fn collectScoped(
    allocator: std.mem.Allocator,
    scope_path: []const u8,
    scope_name: []const u8,
    w: anytype,
    first_in: bool,
) !bool {
    var first = first_in;
    var scope_dir = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch return first;
    defer scope_dir.close();

    var iter = scope_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const pkg_path = try std.fs.path.join(allocator, &.{ scope_path, entry.name });
        defer allocator.free(pkg_path);

        const version = readVersion(allocator, scope_path, entry.name) catch continue;
        defer allocator.free(version);

        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}/{s}\":[\"{s}\"]", .{ scope_name, entry.name, version });
    }
    return first;
}

/// Reads `version` from `<parent>/<name>/package.json`. Caller owns result.
fn readVersion(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ parent, name, "package.json" });
    defer allocator.free(path);

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 256 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("version")) |v| {
            if (v == .string) return allocator.dupe(u8, v.string);
        }
    }
    return error.NoVersion;
}

// ----------------------------------------------------------------------------
// curl POST helper
// ----------------------------------------------------------------------------

/// POSTs `body` as JSON to `url`. Returns the response body. Caller must free.
fn curlPost(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    auth_token: ?[]const u8,
) ![]const u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("curl");
    try argv.append("--silent");
    try argv.append("--show-error");
    try argv.append("--fail");
    try argv.append("-L");
    try argv.append("--max-time");
    try argv.append("30");
    try argv.append("--compressed");
    try argv.append("-A");
    try argv.append("nayr/2.0.0");
    try argv.append("-X");
    try argv.append("POST");
    try argv.append("-H");
    try argv.append("Content-Type: application/json");
    try argv.append("-H");
    try argv.append("Accept: application/json");
    try argv.append("--data");
    try argv.append(body);

    if (auth_token) |tok| {
        const header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{tok});
        try argv.append("-H");
        try argv.append(header);
    }

    try argv.append(url);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 8 * 1024 * 1024);
    errdefer allocator.free(stdout);
    const stderr_buf = try child.stderr.?.reader().readAllAlloc(allocator, 4 * 1024);
    defer allocator.free(stderr_buf);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };

    if (exit_code != 0) {
        allocator.free(stdout);
        return if (exit_code == 22) error.HttpError else error.NetworkError;
    }

    return stdout;
}

// ----------------------------------------------------------------------------
// Response parser & reporter
// ----------------------------------------------------------------------------

/// Severity levels in increasing order of severity.
const LEVELS = [_][]const u8{ "info", "low", "moderate", "high", "critical" };

fn severityIndex(sev: []const u8) usize {
    for (LEVELS, 0..) |l, i| {
        if (std.mem.eql(u8, l, sev)) return i;
    }
    return 0;
}

/// Parses the advisory response and emits a row per vulnerability that meets
/// `min_level`. Emits a summary line at the end.
fn reportVulnerabilities(
    allocator: std.mem.Allocator,
    body: []const u8,
    min_level: []const u8,
    writer: output.Writer,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        writer.emit(.{ .warning = "audit: could not parse registry response" });
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        writer.emit(.{ .info = "audit: found 0 vulnerabilities" });
        return;
    }

    const min_idx = severityIndex(min_level);
    var total: usize = 0;

    var pkg_it = parsed.value.object.iterator();
    while (pkg_it.next()) |pkg_entry| {
        const pkg_name = pkg_entry.key_ptr.*;
        if (pkg_entry.value_ptr.* != .array) continue;

        for (pkg_entry.value_ptr.*.array.items) |adv| {
            if (adv != .object) continue;

            const sev_val = adv.object.get("severity") orelse continue;
            if (sev_val != .string) continue;
            const sev = sev_val.string;
            if (severityIndex(sev) < min_idx) continue;

            total += 1;

            const title = if (adv.object.get("title")) |t|
                if (t == .string) t.string else "unknown"
            else
                "unknown";

            const vuln_range = if (adv.object.get("vulnerable_versions")) |vv|
                if (vv == .string) vv.string else ""
            else
                "";

            const row_label = if (vuln_range.len > 0)
                try std.fmt.allocPrint(allocator, "{s} ({s})", .{ sev, vuln_range })
            else
                try allocator.dupe(u8, sev);
            defer allocator.free(row_label);

            const cols = &[_][]const u8{ pkg_name, row_label, title };
            writer.emit(.{ .table_row = .{ .columns = cols } });
        }
    }

    if (total == 0) {
        writer.emit(.{ .info = "audit: found 0 vulnerabilities" });
    } else {
        const msg = try std.fmt.allocPrint(
            allocator,
            "audit: found {d} vulnerabilit{s} (level >= {s})",
            .{ total, if (total == 1) "y" else "ies", min_level },
        );
        defer allocator.free(msg);
        writer.emit(.{ .warning = msg });
    }
}
