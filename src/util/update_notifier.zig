//! Background update checks (npm-style update notifier).
//!
//! On each CLI invocation nayr may spawn a detached `__update-check` child that
//! queries the registry for the latest published version.  The result is cached
//! in `~/.nayr/update-notifier.json`.  On the **next** run, if the cached
//! latest version is newer than the running binary, a notice is printed.

const std = @import("std");
const semver = @import("../semver/parser.zig");
const platform = @import("platform.zig");
const output = @import("output.zig");

const PACKAGE_NAME = "nayr";
const REGISTRY_URL = "https://registry.npmjs.org/nayr";
const CHECK_INTERVAL_SECS: i64 = 24 * 60 * 60;
const STATE_FILE = "update-notifier.json";

pub const Options = struct {
    silent: bool = false,
    no_color: bool = false,
    format: output.Format = .text,
    disabled: bool = false,
};

pub const UpdateNotifier = struct {
    /// Handles the hidden `nayr __update-check <version>` sub-command.
    ///
    /// @param allocator Scratch allocator for network and file I/O.
    /// @param running_version Version string of the binary that spawned this check.
    /// @returns Nothing; failures are silent.
    pub fn runBackgroundCheck(allocator: std.mem.Allocator, running_version: []const u8) !void {
        const latest = fetchLatestVersion(allocator) catch |err| {
            if (err != error.OutOfMemory) {
                try writeState(allocator, .{
                    .last_checked = std.time.timestamp(),
                    .checked_version = running_version,
                    .latest_version = "",
                });
            }
            return;
        };
        defer allocator.free(latest);

        try writeState(allocator, .{
            .last_checked = std.time.timestamp(),
            .checked_version = running_version,
            .latest_version = latest,
        });
    }

    /// Prints a stale update notice (from a previous background check) and may
    /// spawn a fresh background check for the next run.
    ///
    /// @param allocator Scratch allocator.
    /// @param running_version Embedded build version of this binary.
    /// @param opts Output and opt-out flags.
    /// @returns Nothing; never propagates I/O errors to the caller.
    pub fn onCliStart(
        allocator: std.mem.Allocator,
        running_version: []const u8,
        opts: Options,
    ) void {
        if (opts.disabled or isDisabledByEnv()) return;

        const state = readState(allocator) catch return;
        if (state) |s| {
            defer freeState(allocator, s);
            if (s.latest_version.len > 0 and isNewer(s.latest_version, running_version)) {
                if (!opts.silent and opts.format != .json) {
                    printNotice(running_version, s.latest_version, opts.no_color);
                }
            }
        }

        if (shouldScheduleCheck(allocator, running_version)) {
            spawnBackgroundCheck(allocator, running_version) catch {};
        }
    }
};

const State = struct {
    last_checked: i64,
    checked_version: []const u8,
    latest_version: []const u8,
};

fn isDisabledByEnv() bool {
    if (envTruthy("NO_UPDATE_NOTIFIER")) return true;
    if (envTruthy("NAYR_NO_UPDATE_NOTIFIER")) return true;
    if (envTruthy("CI")) return true;
    return false;
}

fn envTruthy(name: []const u8) bool {
    const v = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(v);
    return std.mem.eql(u8, v, "1") or
        std.mem.eql(u8, v, "true") or
        std.ascii.eqlIgnoreCase(v, "yes");
}

fn isNewer(latest: []const u8, current: []const u8) bool {
    const lv = semver.Version.parse(latest) catch return false;
    const cv = semver.Version.parse(current) catch return false;
    return cv.order(lv) == .lt;
}

fn shouldScheduleCheck(allocator: std.mem.Allocator, running_version: []const u8) bool {
    const state = readState(allocator) catch return true;
    if (state) |s| {
        defer freeState(allocator, s);
        if (!std.mem.eql(u8, s.checked_version, running_version)) return true;
        const now = std.time.timestamp();
        if (now - s.last_checked >= CHECK_INTERVAL_SECS) return true;
        return false;
    }
    return true;
}

fn spawnBackgroundCheck(allocator: std.mem.Allocator, running_version: []const u8) !void {
    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);

    const argv = [_][]const u8{ exe, "__update-check", running_version };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
}

fn fetchLatestVersion(allocator: std.mem.Allocator) ![]const u8 {
    var owned = std.ArrayList([]const u8).init(allocator);
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit();
    }
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("curl");
    try argv.append("-fsSL");
    try argv.append("--max-time");
    try argv.append("15");
    try argv.append("-H");
    try argv.append("Accept: application/vnd.npm.install-v1+json");
    try argv.append(REGISTRY_URL);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const body = try child.stdout.?.reader().readAllAlloc(allocator, 512 * 1024);
    errdefer allocator.free(body);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };
    if (exit_code != 0) {
        allocator.free(body);
        return error.NetworkError;
    }

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    allocator.free(body);

    const root = parsed.value;
    if (root != .object) return error.InvalidMetadata;

    if (root.object.get("dist-tags")) |dt| {
        if (dt == .object) {
            if (dt.object.get("latest")) |latest| {
                if (latest == .string) {
                    return try allocator.dupe(u8, latest.string);
                }
            }
        }
    }

    return error.MissingName;
}

fn statePath(allocator: std.mem.Allocator) ![]const u8 {
    const config_dir = try platform.getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, STATE_FILE });
}

fn readState(allocator: std.mem.Allocator) !?State {
    const path = try statePath(allocator);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        content,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const last_checked: i64 = blk: {
        const v = obj.get("lastChecked") orelse return null;
        if (v == .integer) break :blk v.integer;
        return null;
    };

    const checked_version = blk: {
        const v = obj.get("checkedVersion") orelse return null;
        if (v != .string) return null;
        break :blk try allocator.dupe(u8, v.string);
    };

    const latest_version = blk: {
        const v = obj.get("latestVersion") orelse break :blk try allocator.dupe(u8, "");
        if (v != .string) break :blk try allocator.dupe(u8, "");
        break :blk try allocator.dupe(u8, v.string);
    };

    return State{
        .last_checked = last_checked,
        .checked_version = checked_version,
        .latest_version = latest_version,
    };
}

fn freeState(allocator: std.mem.Allocator, state: State) void {
    allocator.free(state.checked_version);
    allocator.free(state.latest_version);
}

fn writeState(allocator: std.mem.Allocator, state: State) !void {
    const path = try statePath(allocator);
    defer allocator.free(path);

    const config_dir = std.fs.path.dirname(path) orelse return error.BadPathName;
    try std.fs.cwd().makePath(config_dir);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const checked_escaped = try escapeJsonString(allocator, state.checked_version);
    defer allocator.free(checked_escaped);
    const latest_escaped = try escapeJsonString(allocator, state.latest_version);
    defer allocator.free(latest_escaped);

    const content = try std.fmt.allocPrint(
        allocator,
        "{{\"lastChecked\":{d},\"checkedVersion\":\"{s}\",\"latestVersion\":\"{s}\"}}\n",
        .{ state.last_checked, checked_escaped, latest_escaped },
    );
    defer allocator.free(content);

    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);
    }

    try std.fs.renameAbsolute(tmp_path, path);
}

fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (s) |c| {
        switch (c) {
            '"', '\\' => {
                try out.append('\\');
                try out.append(c);
            },
            else => try out.append(c),
        }
    }
    return out.toOwnedSlice();
}

fn printNotice(current: []const u8, latest: []const u8, no_color: bool) void {
    const w = std.io.getStdErr().writer();
    const bold = if (no_color) "" else "\x1b[1m";
    const cyan = if (no_color) "" else "\x1b[36m";
    const reset = if (no_color) "" else "\x1b[0m";

    w.print("{s}nayr{s} notice \n", .{ cyan, reset }) catch {};
    w.print(
        "{s}nayr{s} notice New version of nayr available! {s}{s}{s} -> {s}{s}{s}\n",
        .{ cyan, reset, bold, current, reset, bold, latest, reset },
    ) catch {};
    w.print(
        "{s}nayr{s} notice Run {s}npm install -g nayr@latest{s} to update.\n",
        .{ cyan, reset, bold, reset },
    ) catch {};
    w.print("{s}nayr{s} notice \n", .{ cyan, reset }) catch {};
}

test "isNewer detects newer semver and pre-release" {
    try std.testing.expect(isNewer("2.0.0", "1.0.0"));
    try std.testing.expect(isNewer("2.0.0-beta.27", "2.0.0-beta.26"));
    try std.testing.expect(!isNewer("2.0.0-beta.26", "2.0.0-beta.26"));
    try std.testing.expect(!isNewer("2.0.0-beta.25", "2.0.0-beta.26"));
}

test "escapeJsonString escapes quotes" {
    const allocator = std.testing.allocator;
    const escaped = try escapeJsonString(allocator, "a\"b");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\\"b", escaped);
}
