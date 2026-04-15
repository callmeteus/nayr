//! JSON and package.json Utilities
//!
//! Thin wrappers around `std.json` for working with npm package.json files.
//! The `PackageJson` struct covers all fields relevant to nayr; unknown fields
//! are silently ignored during parsing.

const std = @import("std");

// ============================================================================
// PackageJson
// ============================================================================

/// A parsed `package.json` file.
///
/// Only fields consumed by nayr are represented here. All fields are optional
/// because package.json has no required fields beyond what npm validates at
/// publish time, and nayr must be able to process incomplete manifests.
pub const PackageJson = struct {
    /// Package name (e.g. "@luckymaker/backend").
    name: ?[]const u8 = null,

    /// Version string (e.g. "1.2.3").
    version: ?[]const u8 = null,

    /// Main entry point (e.g. "dist/index.js").
    main: ?[]const u8 = null,

    /// Whether the package is private (prevents accidental publish).
    private: bool = false,

    /// Runtime dependencies.
    dependencies: StringMap = .{},

    /// Development dependencies (not installed in --production mode).
    dev_dependencies: StringMap = .{},

    /// Peer dependencies (installed by the consumer, not this package).
    peer_dependencies: StringMap = .{},

    /// Optional dependencies (ignored on failure).
    optional_dependencies: StringMap = .{},

    /// Scripts defined for the package.
    scripts: StringMap = .{},

    /// Executable binaries exposed by the package.
    bin: BinField = .none,

    /// Workspace configuration (root package.json only).
    workspaces: WorkspacesField = .none,

    /// Resolution overrides (Yarn `resolutions` field).
    resolutions: StringMap = .{},

    /// Files to include when publishing (`.npmignore` alternative).
    files: []const []const u8 = &.{},

    /// Engine constraints (e.g. `{"node": ">=18"}`).
    engines: StringMap = .{},

    /// A map of string → string used for dependency maps.
    pub const StringMap = std.StringHashMapUnmanaged([]const u8);

    /// The `bin` field in package.json can be either a string (single binary
    /// with the package name) or an object (multiple named binaries).
    pub const BinField = union(enum) {
        none,
        /// Single binary: `"bin": "./cli.js"` - name = package name.
        single: []const u8,
        /// Multiple binaries: `"bin": { "cmd": "./cmd.js" }`.
        map: StringMap,
    };

    /// The `workspaces` field can be an array of globs or an object with
    /// `packages` and optional `nohoist`.
    pub const WorkspacesField = union(enum) {
        none,
        /// Simple array form: `"workspaces": ["packages/*"]`.
        globs: []const []const u8,
        /// Extended form: `{ "packages": [...], "nohoist": [...] }`.
        extended: Extended,

        pub const Extended = struct {
            packages: []const []const u8,
            nohoist: []const []const u8 = &.{},
        };
    };

    /// Frees all memory owned by this struct.
    pub fn deinit(self: *PackageJson, allocator: std.mem.Allocator) void {
        self.dependencies.deinit(allocator);
        self.dev_dependencies.deinit(allocator);
        self.peer_dependencies.deinit(allocator);
        self.optional_dependencies.deinit(allocator);
        self.scripts.deinit(allocator);
        self.resolutions.deinit(allocator);
        self.engines.deinit(allocator);
        if (self.bin == .map) self.bin.map.deinit(allocator);
    }
};

// ============================================================================
// Parsing
// ============================================================================

/// Parses a `package.json` file from the given path.
///
/// ## Parameters
/// - `allocator`: All strings and maps are allocated here.
/// - `path`: Absolute path to the `package.json` file.
///
/// ## Returns
/// A fully populated `PackageJson`, or an error if the file cannot be read
/// or is not valid JSON.
pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !PackageJson {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 4 * 1024 * 1024); // 4 MB max
    defer allocator.free(contents);
    return parseSlice(allocator, contents);
}

/// Parses a `package.json` from an in-memory byte slice.
///
/// ## Parameters
/// - `allocator`: All strings and maps are allocated here.
/// - `json`: UTF-8 encoded JSON bytes.
pub fn parseSlice(allocator: std.mem.Allocator, json: []const u8) !PackageJson {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidPackageJson;

    var pkg = PackageJson{};

    // --- Scalar string fields ---
    pkg.name = try dupeOptStr(allocator, root.object.get("name"));
    pkg.version = try dupeOptStr(allocator, root.object.get("version"));
    pkg.main = try dupeOptStr(allocator, root.object.get("main"));

    if (root.object.get("private")) |pv| {
        pkg.private = switch (pv) {
            .bool => |b| b,
            else => false,
        };
    }

    // --- Dependency maps ---
    pkg.dependencies = try parseStringMap(allocator, root.object.get("dependencies"));
    pkg.dev_dependencies = try parseStringMap(allocator, root.object.get("devDependencies"));
    pkg.peer_dependencies = try parseStringMap(allocator, root.object.get("peerDependencies"));
    pkg.optional_dependencies = try parseStringMap(allocator, root.object.get("optionalDependencies"));
    pkg.scripts = try parseStringMap(allocator, root.object.get("scripts"));
    pkg.resolutions = try parseStringMap(allocator, root.object.get("resolutions"));
    pkg.engines = try parseStringMap(allocator, root.object.get("engines"));

    // --- bin field ---
    if (root.object.get("bin")) |bin_val| {
        switch (bin_val) {
            .string => |s| pkg.bin = .{ .single = try allocator.dupe(u8, s) },
            .object => pkg.bin = .{ .map = try parseStringMap(allocator, bin_val) },
            else => {},
        }
    }

    // --- workspaces field ---
    if (root.object.get("workspaces")) |ws_val| {
        switch (ws_val) {
            .array => |arr| {
                var globs = try std.ArrayList([]const u8).initCapacity(allocator, arr.items.len);
                for (arr.items) |item| {
                    if (item == .string) try globs.append(try allocator.dupe(u8, item.string));
                }
                pkg.workspaces = .{ .globs = try globs.toOwnedSlice() };
            },
            .object => |obj| {
                const pkgs_val = obj.get("packages");
                const nohoist_val = obj.get("nohoist");
                const pkgs = try parseStringArray(allocator, pkgs_val);
                const nohoist = try parseStringArray(allocator, nohoist_val);
                pkg.workspaces = .{ .extended = .{ .packages = pkgs, .nohoist = nohoist } };
            },
            else => {},
        }
    }

    return pkg;
}

// ============================================================================
// Helpers
// ============================================================================

/// Duplicates the string value of a JSON value, or returns null.
fn dupeOptStr(allocator: std.mem.Allocator, val: ?std.json.Value) !?[]const u8 {
    const v = val orelse return null;
    if (v != .string) return null;
    return @as([]const u8, try allocator.dupe(u8, v.string));
}

/// Parses a JSON object as a `StringMap` (string → string).
/// Non-string values are skipped.
fn parseStringMap(allocator: std.mem.Allocator, val: ?std.json.Value) !PackageJson.StringMap {
    var map = PackageJson.StringMap{};
    const v = val orelse return map;
    if (v != .object) return map;
    var it = v.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const value = try allocator.dupe(u8, entry.value_ptr.*.string);
        try map.put(allocator, key, value);
    }
    return map;
}

/// Parses a JSON array of strings.
fn parseStringArray(allocator: std.mem.Allocator, val: ?std.json.Value) ![]const []const u8 {
    const v = val orelse return &.{};
    if (v != .array) return &.{};
    var list = try std.ArrayList([]const u8).initCapacity(allocator, v.array.items.len);
    for (v.array.items) |item| {
        if (item == .string) try list.append(try allocator.dupe(u8, item.string));
    }
    return list.toOwnedSlice();
}
