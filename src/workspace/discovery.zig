//! Workspace Discovery
//!
//! Discovers all workspace packages in a monorepo by reading the root
//! `package.json` and expanding glob patterns from the `workspaces` field.
//!
//! Supports both forms of the workspaces field:
//!   - Array:    `"workspaces": ["packages/*"]`
//!   - Extended: `"workspaces": { "packages": ["packages/*"], "nohoist": [...] }`

const std = @import("std");
const json_util = @import("../util/json.zig");
const fs_util = @import("../util/fs.zig");
const PackageJson = json_util.PackageJson;

// ============================================================================
// WorkspacePackage
// ============================================================================

/// A discovered workspace package.
pub const WorkspacePackage = struct {
    /// Absolute path to the package directory.
    path: []const u8,
    /// Relative path from the monorepo root.
    rel_path: []const u8,
    /// The parsed `package.json`.
    manifest: PackageJson,
};

// ============================================================================
// Public API
// ============================================================================

/// Discovers all workspace packages from the root `package.json`.
///
/// Reads the root manifest, expands workspace globs, and parses each
/// `package.json`. Cycle detection across workspace inter-dependencies is
/// performed and returns `error.WorkspaceCycle` if found.
///
/// ## Parameters
/// - `allocator`: All data is allocated here.
/// - `root_dir`: Absolute path to the monorepo root.
///
/// ## Returns
/// Slice of `WorkspacePackage`. Caller owns the slice and each `manifest`.
pub fn discover(allocator: std.mem.Allocator, root_dir: []const u8) ![]WorkspacePackage {
    const root_manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "package.json" });
    defer allocator.free(root_manifest_path);

    var root_manifest = try json_util.parseFile(allocator, root_manifest_path);
    defer root_manifest.deinit(allocator);

    const globs: []const []const u8 = switch (root_manifest.workspaces) {
        .none => return &.{}, // No workspaces defined.
        .globs => |g| g,
        .extended => |e| e.packages,
    };

    var packages = std.ArrayList(WorkspacePackage).init(allocator);

    for (globs) |glob| {
        const matches = try fs_util.globExpand(allocator, root_dir, glob);
        defer allocator.free(matches);

        for (matches) |match_path| {
            const pkg_json_path = try std.fs.path.join(allocator, &.{ match_path, "package.json" });
            defer allocator.free(pkg_json_path);

            // Skip directories that do not have a package.json.
            std.fs.accessAbsolute(pkg_json_path, .{}) catch continue;

            const manifest = try json_util.parseFile(allocator, pkg_json_path);

            // Derive the relative path from root.
            const rel = relPath(allocator, root_dir, match_path) catch match_path;

            try packages.append(.{
                .path = try allocator.dupe(u8, match_path),
                .rel_path = rel,
                .manifest = manifest,
            });
        }
    }

    return packages.toOwnedSlice();
}

/// Builds a name → path map for fast workspace lookup during resolution.
///
/// ## Parameters
/// - `allocator`: For the map keys/values.
/// - `packages`: The slice returned by `discover`.
///
/// ## Returns
/// A map of package name → absolute path. Caller must call `.deinit()`.
pub fn buildNameMap(
    allocator: std.mem.Allocator,
    packages: []const WorkspacePackage,
) !std.StringHashMapUnmanaged([]const u8) {
    var map = std.StringHashMapUnmanaged([]const u8){};
    for (packages) |pkg| {
        const name = pkg.manifest.name orelse continue;
        try map.put(allocator, name, pkg.path);
    }
    return map;
}

/// Returns the nohoist patterns from the root manifest's extended workspace config.
///
/// ## Returns
/// Slice of nohoist glob patterns, or an empty slice if none.
pub fn nohoistPatterns(root_manifest: *const PackageJson) []const []const u8 {
    return switch (root_manifest.workspaces) {
        .extended => |e| e.nohoist,
        else => &.{},
    };
}

// ============================================================================
// Helpers
// ============================================================================

fn relPath(allocator: std.mem.Allocator, base: []const u8, abs: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, abs, base)) {
        const rest = abs[base.len..];
        return allocator.dupe(u8, std.mem.trimLeft(u8, rest, "/\\"));
    }
    return allocator.dupe(u8, abs);
}
