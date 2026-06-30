//! Frozen lockfile validation (`--frozen-lockfile` / Yarn Classic parity).
//!
//! When frozen mode is on, nayr must refuse to install if `package.json` and
//! the lockfile are out of sync, or if resolution would change the lockfile.

const std = @import("std");
const lockfile_types = @import("../lockfile/types.zig");
const json_util = @import("../util/json.zig");
const nayr_fmt = @import("../lockfile/nayr_format.zig");
const yarn_v1 = @import("../lockfile/yarn_v1.zig");
const ws_discovery = @import("../workspace/discovery.zig");
const output = @import("../util/output.zig");
const platform = @import("../util/platform.zig");
const PackageJson = json_util.PackageJson;
const Lockfile = lockfile_types.Lockfile;

/// Options shared with the resolver for manifest walks.
pub const CheckOptions = struct {
    production: bool = false,
    ignore_optional: bool = false,
};

pub const FrozenLockfile = struct {
    /// Validates that direct manifest dependencies are already covered by the
    /// lockfile.  Used before the integrity fast-path and at resolve start.
    ///
    /// @param allocator Scratch allocator for temporary strings.
    /// @param root_dir Absolute project root.
    /// @param opts Install flags affecting which dependency maps are scanned.
    /// @param writer Output sink for the Yarn-style error line.
    /// @returns Nothing, or `error.FrozenLockfileChanged` when out of sync.
    pub fn validateManifests(
        allocator: std.mem.Allocator,
        root_dir: []const u8,
        opts: CheckOptions,
        writer: output.Writer,
    ) !void {
        var lock = try loadExistingLockfile(allocator, root_dir);
        defer lock.deinit(allocator);

        var links_map = try loadLinksRegistry(allocator);
        defer {
            var lm_it = links_map.iterator();
            while (lm_it.next()) |kv| {
                allocator.free(kv.key_ptr.*);
                allocator.free(kv.value_ptr.*);
            }
            links_map.deinit(allocator);
        }

        const root_manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "package.json" });
        defer allocator.free(root_manifest_path);
        var root_manifest = try json_util.parseFile(allocator, root_manifest_path);
        defer root_manifest.deinit(allocator);

        var overrides = std.StringHashMapUnmanaged([]const u8){};
        defer overrides.deinit(allocator);
        var ov_it = root_manifest.resolutions.iterator();
        while (ov_it.next()) |kv| {
            try overrides.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
        }

        var workspace_names = std.StringHashMapUnmanaged(void){};
        defer workspace_names.deinit(allocator);
        if (root_manifest.name) |n| try workspace_names.put(allocator, n, {});

        const workspaces = try ws_discovery.discover(allocator, root_dir);
        defer {
            for (workspaces) |*ws| {
                ws.manifest.deinit(allocator);
                allocator.free(ws.path);
                allocator.free(ws.rel_path);
            }
            allocator.free(workspaces);
        }
        for (workspaces) |*ws| {
            if (ws.manifest.name) |n| try workspace_names.put(allocator, n, {});
        }

        try FrozenLockfile.validateLoadedManifests(
            allocator,
            &lock,
            &root_manifest,
            workspaces,
            &overrides,
            &workspace_names,
            &links_map,
            opts,
            writer,
        );
    }

    /// Same as `validateManifests` but reuses lockfile and manifests already
    /// loaded by the resolver.
    ///
    /// @param allocator Scratch allocator for temporary strings.
    /// @param lock Existing lockfile from disk.
    /// @param root_manifest Root package manifest.
    /// @param workspaces Workspace packages discovered under the project root.
    /// @param overrides Root `resolutions` field entries.
    /// @param workspace_names Names of workspace packages in this repo.
    /// @param links_map Combined nayr/yarn link registry.
    /// @param opts Install flags affecting which dependency maps are scanned.
    /// @param writer Output sink for the Yarn-style error line.
    /// @returns Nothing, or `error.FrozenLockfileChanged` when out of sync.
    pub fn validateLoadedManifests(
        allocator: std.mem.Allocator,
        lock: *const Lockfile,
        root_manifest: *const PackageJson,
        workspaces: []const ws_discovery.WorkspacePackage,
        overrides: *const std.StringHashMapUnmanaged([]const u8),
        workspace_names: *const std.StringHashMapUnmanaged(void),
        links_map: *const std.StringHashMapUnmanaged([]const u8),
        opts: CheckOptions,
        writer: output.Writer,
    ) !void {
        if (lock.entries.len == 0) {
            try emitError(allocator, writer, "no lockfile found");
            return error.FrozenLockfileChanged;
        }

        try checkManifestDeps(allocator, lock, root_manifest, overrides, workspace_names, links_map, opts, writer);
        for (workspaces) |*ws| {
            try checkManifestDeps(allocator, lock, &ws.manifest, overrides, workspace_names, links_map, opts, writer);
        }
    }

    /// Refuses when the resolved lockfile would differ from the one on disk.
    ///
    /// @param existing Lockfile loaded at the start of resolve.
    /// @param resolved Lockfile built after resolution.
    /// @param allocator Scratch allocator for error text.
    /// @param writer Output sink for the Yarn-style error line.
    /// @returns Nothing, or `error.FrozenLockfileChanged` when they differ.
    pub fn assertUnchanged(
        existing: *const Lockfile,
        resolved: *const Lockfile,
        allocator: std.mem.Allocator,
        writer: output.Writer,
    ) !void {
        if (existing.entries.len == 0) return;
        if (Lockfile.semanticEqual(existing, resolved)) return;
        try emitError(allocator, writer, "resolution would modify the lockfile");
        return error.FrozenLockfileChanged;
    }

    /// Emits the standard frozen-lockfile error for a missing direct dependency.
    ///
    /// @param allocator Scratch allocator for the formatted message.
    /// @param writer Output sink.
    /// @param name Package name from `package.json`.
    /// @param range Version range or git URL from `package.json`.
    /// @returns Nothing, or `error.FrozenLockfileChanged`.
    pub fn failMissingDep(
        allocator: std.mem.Allocator,
        writer: output.Writer,
        name: []const u8,
        range: []const u8,
    ) !void {
        const hint = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ name, range });
        defer allocator.free(hint);
        try emitError(allocator, writer, hint);
        return error.FrozenLockfileChanged;
    }

    /// Emits the standard frozen-lockfile error with a free-form hint line.
    ///
    /// @param allocator Scratch allocator for the formatted message.
    /// @param writer Output sink.
    /// @param hint Detail line describing what is out of sync.
    /// @returns Nothing, or `error.FrozenLockfileChanged`.
    pub fn failWithHint(
        allocator: std.mem.Allocator,
        writer: output.Writer,
        hint: []const u8,
    ) !void {
        try emitError(allocator, writer, hint);
        return error.FrozenLockfileChanged;
    }
};

fn checkManifestDeps(
    allocator: std.mem.Allocator,
    lock: *const Lockfile,
    manifest: *const PackageJson,
    overrides: *const std.StringHashMapUnmanaged([]const u8),
    workspace_names: *const std.StringHashMapUnmanaged(void),
    links_map: *const std.StringHashMapUnmanaged([]const u8),
    opts: CheckOptions,
    writer: output.Writer,
) !void {
    const dep_maps = [_]struct {
        map: *const std.StringHashMapUnmanaged([]const u8),
        skip: bool,
    }{
        .{ .map = &manifest.dev_dependencies, .skip = opts.production },
        .{ .map = &manifest.dependencies, .skip = false },
        .{ .map = &manifest.optional_dependencies, .skip = opts.ignore_optional },
    };

    for (dep_maps) |dm| {
        if (dm.skip) continue;
        var it = dm.map.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const range = overrides.get(name) orelse kv.value_ptr.*;

            if (workspace_names.contains(name)) continue;
            if (isWorkspaceRange(range)) continue;
            if (links_map.contains(name)) continue;

            const pattern = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ name, range });
            defer allocator.free(pattern);

            if (lock.get(pattern) == null) {
                try FrozenLockfile.failMissingDep(allocator, writer, name, range);
            }
        }
    }
}

/// Emits the Yarn-style frozen-lockfile error.
///
/// @param allocator Scratch allocator for the message body.
/// @param writer Output sink.
/// @param hint Detail line (e.g. missing pattern); use empty string when none.
/// @returns Nothing.
fn emitError(allocator: std.mem.Allocator, writer: output.Writer, hint: []const u8) !void {
    const msg = if (hint.len > 0)
        try std.fmt.allocPrint(
            allocator,
            "Your lockfile needs to be updated, but nayr was run with `--frozen-lockfile`.\n" ++
                "Out of sync: {s}\n" ++
                "Run `nayr install` locally to update the lockfile.",
            .{hint},
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "Your lockfile needs to be updated, but nayr was run with `--frozen-lockfile`.\n" ++
                "Run `nayr install` locally to update the lockfile.",
            .{},
        );
    defer allocator.free(msg);
    writer.emit(.{ .err = msg });
}

fn isWorkspaceRange(range: []const u8) bool {
    return std.mem.eql(u8, range, "workspace:*") or std.mem.startsWith(u8, range, "workspace:");
}

fn loadExistingLockfile(allocator: std.mem.Allocator, root_dir: []const u8) !Lockfile {
    const nayr_lock_path = try std.fs.path.join(allocator, &.{ root_dir, "nayr.lock" });
    defer allocator.free(nayr_lock_path);
    const yarn_lock_path = try std.fs.path.join(allocator, &.{ root_dir, "yarn.lock" });
    defer allocator.free(yarn_lock_path);

    if (std.fs.accessAbsolute(nayr_lock_path, .{})) |_| {
        if (nayr_fmt.parseFile(allocator, nayr_lock_path)) |lock| {
            return lock;
        } else |err| {
            if (err != error.NotNayrLockfile) return err;
        }
    } else |_| {}

    if (std.fs.accessAbsolute(yarn_lock_path, .{})) |_| {
        return try yarn_v1.parseFile(allocator, yarn_lock_path);
    } else |_| {}

    return Lockfile.init();
}

fn loadLinksRegistry(allocator: std.mem.Allocator) !std.StringHashMapUnmanaged([]const u8) {
    var map = std.StringHashMapUnmanaged([]const u8){};

    const nayr_dir = platform.getLinksDir(allocator) catch return map;
    defer allocator.free(nayr_dir);
    try walkLinksIntoMap(allocator, nayr_dir, &map, false);

    const yarn_dir = platform.getYarnLinksDir(allocator) catch return map;
    defer allocator.free(yarn_dir);
    try walkLinksIntoMap(allocator, yarn_dir, &map, true);

    return map;
}

fn walkLinksIntoMap(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    map: *std.StringHashMapUnmanaged([]const u8),
    skip_existing: bool,
) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .sym_link) {
            if (skip_existing and map.contains(entry.name)) continue;
            const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(full);
            const target = platform.readSymlinkAbsolute(allocator, full) catch continue;
            const name_owned = try allocator.dupe(u8, entry.name);
            try map.put(allocator, name_owned, target);
        } else if (entry.kind == .directory and entry.name[0] == '@') {
            const scope_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(scope_path);
            var sd = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch continue;
            defer sd.close();
            var sit = sd.iterate();
            while (try sit.next()) |se| {
                if (se.kind != .sym_link) continue;
                const scoped = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, se.name });
                if (skip_existing and map.contains(scoped)) {
                    allocator.free(scoped);
                    continue;
                }
                const full = try std.fs.path.join(allocator, &.{ scope_path, se.name });
                defer allocator.free(full);
                const target = platform.readSymlinkAbsolute(allocator, full) catch {
                    allocator.free(scoped);
                    continue;
                };
                try map.put(allocator, scoped, target);
            }
        }
    }
}
