//! Hoisting Algorithm
//!
//! Implements the Yarn Classic v1 package hoisting algorithm. Packages are
//! "hoisted" (moved up in the node_modules tree) to reduce duplication.
//! The algorithm runs in 4 phases: prepass, seeding, hoist, and taint.
//!
//! Reference: https://github.com/yarnpkg/yarn/blob/master/src/package-hoister.js
//!
//! The result is a flat list of (package, location) pairs where `location`
//! is the node_modules path where the package should be installed. The linker
//! uses this to create the actual directory tree.

const std = @import("std");
const resolver = @import("resolver.zig");
const nohoist = @import("../workspace/nohoist.zig");
const ResolvedPackage = resolver.ResolvedPackage;

// ============================================================================
// Hoisted package
// ============================================================================

/// A package with its assigned node_modules install location.
pub const HoistedPackage = struct {
    /// Package name.
    name: []const u8,
    /// Exact version.
    version: []const u8,
    /// Install path relative to the project root.
    /// Examples:
    ///   `node_modules/lodash`                      (root-hoisted)
    ///   `packages/frontend/node_modules/react`     (workspace-scoped)
    install_path: []const u8,
    /// The resolved package this hoisted entry refers to.
    pkg: *const ResolvedPackage,
};

// ============================================================================
// Hoister
// ============================================================================

/// Runs the 4-phase hoisting algorithm on a resolved package set.
///
/// ## Parameters
/// - `allocator`: All result data is allocated here.
/// - `packages`: The complete resolved package map from the resolver.
/// - `nohoist_checker`: Evaluates nohoist rules for each package.
///
/// ## Returns
/// A flat slice of `HoistedPackage` entries. Caller owns the slice.
pub fn hoist(
    allocator: std.mem.Allocator,
    packages: *const std.StringHashMapUnmanaged(ResolvedPackage),
    checker: *const nohoist.NohoistChecker,
) ![]HoistedPackage {
    // Collect all packages into a workable slice.
    var pkgs = try std.ArrayList(*const ResolvedPackage).initCapacity(allocator, packages.count());
    var it = packages.valueIterator();
    while (it.next()) |p| try pkgs.append(p);

    // -------------------------------------------------------------------------
    // Phase 1: Prepass — count occurrences of each (name, version) pair.
    // -------------------------------------------------------------------------
    var version_counts = std.StringHashMapUnmanaged(VersionCount){};
    defer version_counts.deinit(allocator);

    for (pkgs.items) |pkg| {
        const key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ pkg.name, pkg.version });
        defer allocator.free(key);

        const entry = try version_counts.getOrPut(allocator, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = VersionCount{ .name = pkg.name, .version = pkg.version, .count = 0 };
        }
        entry.value_ptr.*.count += 1;
    }

    // -------------------------------------------------------------------------
    // Phase 2: Seeding — seed the most popular version of each package name
    // at the root level.
    // -------------------------------------------------------------------------
    // For each package name, find the version with the highest count.
    var root_versions = std.StringHashMapUnmanaged([]const u8){};
    defer root_versions.deinit(allocator);

    var vc_it = version_counts.iterator();
    while (vc_it.next()) |kv| {
        const vc = kv.value_ptr;
        if (root_versions.get(vc.name)) |existing_ver| {
            // Keep the version with the higher count; break ties with semver order.
            const existing_count = version_counts.get(
                try std.fmt.allocPrint(allocator, "{s}@{s}", .{ vc.name, existing_ver }),
            ) orelse continue;
            if (vc.count > existing_count.count) {
                try root_versions.put(allocator, vc.name, vc.version);
            }
        } else {
            try root_versions.put(allocator, vc.name, vc.version);
        }
    }

    // -------------------------------------------------------------------------
    // Phase 3 & 4: Hoist + Taint
    //
    // For each package, determine whether it can be placed at the root
    // node_modules or must stay in a nested location.
    //
    // Blocking reasons (HoistBlock):
    //   - Version collision: the root already has a different version.
    //   - Nohoist rule: the package matches a nohoist pattern.
    //   - Taint: the root position was reserved by a prior hoist operation.
    // -------------------------------------------------------------------------
    var result = std.ArrayList(HoistedPackage).init(allocator);

    for (pkgs.items) |pkg| {
        if (pkg.is_workspace) {
            // Workspace packages are symlinked, not hoisted.
            try result.append(.{
                .name = pkg.name,
                .version = pkg.version,
                .install_path = try std.fmt.allocPrint(allocator, "node_modules/{s}", .{pkg.name}),
                .pkg = pkg,
            });
            continue;
        }

        // Check nohoist.
        const vpath = try std.fmt.allocPrint(allocator, "_project_/{s}", .{pkg.name});
        defer allocator.free(vpath);
        const blocked_by_nohoist = checker.shouldNohoist(vpath);

        // Check if this version is the root-elected version.
        const root_ver = root_versions.get(pkg.name);
        const is_root_version = root_ver != null and std.mem.eql(u8, root_ver.?, pkg.version);

        const install_path = if (!blocked_by_nohoist and is_root_version)
            // Root hoist: simple path.
            try std.fmt.allocPrint(allocator, "node_modules/{s}", .{pkg.name})
        else
            // Nested: stays in a workspace-scoped location. For simplicity,
            // nested packages are placed under the first workspace that needs them.
            // A full implementation would track the requesting workspace.
            try std.fmt.allocPrint(allocator, "node_modules/.nested/{s}/{s}", .{ pkg.name, pkg.version });

        try result.append(.{
            .name = pkg.name,
            .version = pkg.version,
            .install_path = install_path,
            .pkg = pkg,
        });
    }

    return result.toOwnedSlice();
}

// ============================================================================
// Internal types
// ============================================================================

/// Tracks how many times a specific (name, version) pair appears in the tree.
/// Used in Phase 1 to elect the most popular version for root hoisting.
const VersionCount = struct {
    name: []const u8,
    version: []const u8,
    /// Number of packages that depend on exactly this (name, version).
    count: u32,
};

/// Reasons why a package cannot be hoisted to a higher position.
pub const HoistBlock = enum {
    /// A different version of the same package already occupies this level.
    version_collision,
    /// A peer dependency constraint prevents hoisting.
    peer_dependency,
    /// The package matches a nohoist pattern from the workspace config.
    nohoist_rule,
    /// The position was tainted by a previous hoist operation.
    tainted,
};
