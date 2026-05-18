//! Hoisting Algorithm
//!
//! Implements a package hoisting algorithm compatible with npm/Yarn Classic.
//! Packages are "hoisted" (moved up in the node_modules tree) to reduce
//! duplication. The algorithm runs in 4 phases:
//!
//!   1. Prepass   - count how many resolved packages share each name.
//!   2. Seeding   - elect the "best" (most popular, then newest) version of
//!                  each package for root-level placement.
//!   3. Hoist     - assign root install paths; skip non-root versions for now.
//!   4. Resolve   - for every root-hoisted package, check if its declared
//!                  dependency ranges are satisfied by the root-elected version
//!                  of each dep. If not, install the correct version nested
//!                  directly inside that package's node_modules subdirectory.
//!
//! ## Why Phase 4 matters
//!
//! When a package P requires `dep@^2.x` but the root has `dep@4.x`, Node.js
//! module resolution will find the wrong version. The fix is to place
//! `dep@2.x` at `node_modules/<P>/node_modules/<dep>` so that Node.js finds
//! it before the root entry.

const std = @import("std");
const resolver = @import("resolver.zig");
const nohoist = @import("../workspace/nohoist.zig");
const semver = @import("../semver/parser.zig");
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
    ///   `node_modules/lodash`                          (root-hoisted)
    ///   `node_modules/lazystream/node_modules/readable-stream`  (nested)
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
/// - `checker`: Evaluates nohoist rules for each package.
/// - `root_dep_ranges`: Direct dependency ranges declared in the root
///   `package.json` (dependencies + devDependencies + optionalDependencies).
///   These packages always win the root `node_modules` slot, regardless of
///   how many transitive packages depend on a different version.
///
/// ## Returns
/// A flat slice of `HoistedPackage` entries. Caller owns the slice.
pub fn hoist(
    allocator: std.mem.Allocator,
    packages: *const std.StringHashMapUnmanaged(ResolvedPackage),
    checker: *const nohoist.NohoistChecker,
    root_dep_ranges: *const std.StringHashMapUnmanaged([]const u8),
) ![]HoistedPackage {
    // Collect all packages into a workable slice.
    var pkgs = try std.ArrayList(*const ResolvedPackage).initCapacity(allocator, packages.count());
    defer pkgs.deinit();
    var it = packages.valueIterator();
    while (it.next()) |p| try pkgs.append(p);

    // -------------------------------------------------------------------------
    // Phase 1: Prepass - count how many entries share a (name, version) key.
    // -------------------------------------------------------------------------
    var version_counts = std.StringHashMapUnmanaged(VersionCount){};
    defer {
        var vc_free_it = version_counts.keyIterator();
        while (vc_free_it.next()) |k| allocator.free(k.*);
        version_counts.deinit(allocator);
    }

    for (pkgs.items) |pkg| {
        const key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ pkg.name, pkg.version });
        const entry = try version_counts.getOrPut(allocator, key);
        if (entry.found_existing) {
            allocator.free(key);
        } else {
            entry.value_ptr.* = VersionCount{ .name = pkg.name, .version = pkg.version, .count = 0 };
        }
        entry.value_ptr.*.count += 1;
    }

    // -------------------------------------------------------------------------
    // Phase 2: Seeding - elect the root version for each package name.
    //
    // Phase 2a: Root direct dependencies always win their slot.  A package
    // declared in the root package.json must appear at the root
    // `node_modules/<name>` level so that the application's own imports
    // resolve to the pinned version.  If a transitive dependency requires a
    // DIFFERENT version of the same package, it is handled in Phase 4 via
    // nesting - never by overriding the root's choice here.
    //
    // Phase 2b: For names not pinned by Phase 2a, elect the most-depended-on
    // version (highest count).  Break ties by newness: a newer release
    // satisfies a strict superset of ranges, minimising Phase 4 nesting.
    // -------------------------------------------------------------------------
    var root_versions = std.StringHashMapUnmanaged([]const u8){};
    defer root_versions.deinit(allocator);

    // Phase 2a: pin root direct deps regardless of popularity.
    {
        var rdr_it = root_dep_ranges.iterator();
        while (rdr_it.next()) |kv| {
            const dep_name = kv.key_ptr.*;
            const dep_range = kv.value_ptr.*;
            // Find the highest resolved version that satisfies this range.
            // The resolver always produces at most one matching version for a
            // given root range, but we use a max-satisfying scan for safety.
            var best: ?[]const u8 = null;
            var scan_it = version_counts.iterator();
            while (scan_it.next()) |scan_kv| {
                const vc = scan_kv.value_ptr;
                if (!std.mem.eql(u8, vc.name, dep_name)) continue;
                if (!semver.satisfies(allocator, vc.version, dep_range)) continue;
                if (best == null or semver.compareVersions(vc.version, best.?) == .gt) {
                    best = vc.version;
                }
            }
            if (best) |ver| try root_versions.put(allocator, dep_name, ver);
        }
    }

    // Phase 2b: popularity+newness for packages not already pinned.
    var vc_it = version_counts.iterator();
    while (vc_it.next()) |kv| {
        const vc = kv.value_ptr;
        // Skip names already pinned by Phase 2a.
        if (root_versions.contains(vc.name)) continue;
        if (root_versions.get(vc.name)) |existing_ver| {
            const lookup_key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ vc.name, existing_ver });
            defer allocator.free(lookup_key);
            const existing_count = version_counts.get(lookup_key) orelse continue;
            const newer = semver.compareVersions(vc.version, existing_ver) == .gt;
            if (vc.count > existing_count.count or (vc.count == existing_count.count and newer)) {
                try root_versions.put(allocator, vc.name, vc.version);
            }
        } else {
            try root_versions.put(allocator, vc.name, vc.version);
        }
    }

    // -------------------------------------------------------------------------
    // Phase 3: Hoist - assign root install paths to root-elected packages.
    //
    // Non-root versions are NOT placed at any path here; Phase 4 will insert
    // them nested directly under their dependents where they are needed.
    // -------------------------------------------------------------------------

    // Build name → list-of-all-resolved-packages for Phase 4 lookups.
    var name_to_pkgs = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*const ResolvedPackage)){};
    defer {
        var ntp_it = name_to_pkgs.iterator();
        while (ntp_it.next()) |kv| kv.value_ptr.deinit(allocator);
        name_to_pkgs.deinit(allocator);
    }
    for (pkgs.items) |pkg| {
        const gop = try name_to_pkgs.getOrPut(allocator, pkg.name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.append(allocator, pkg);
    }

    var result = std.ArrayList(HoistedPackage).init(allocator);

    // Track install_paths already added to avoid duplicate nested entries.
    var added_paths = std.StringHashMapUnmanaged(void){};
    defer added_paths.deinit(allocator);

    for (pkgs.items) |pkg| {
        if (pkg.is_workspace) {
            const ip = try std.fmt.allocPrint(allocator, "node_modules/{s}", .{pkg.name});
            try result.append(.{ .name = pkg.name, .version = pkg.version, .install_path = ip, .pkg = pkg });
            try added_paths.put(allocator, ip, {});
            continue;
        }

        // Check nohoist.
        const vpath = try std.fmt.allocPrint(allocator, "_project_/{s}", .{pkg.name});
        defer allocator.free(vpath);
        const blocked_by_nohoist = checker.shouldNohoist(vpath);

        const root_ver = root_versions.get(pkg.name);
        const is_root_version = root_ver != null and std.mem.eql(u8, root_ver.?, pkg.version);

        if (!blocked_by_nohoist and is_root_version) {
            const ip = try std.fmt.allocPrint(allocator, "node_modules/{s}", .{pkg.name});
            try result.append(.{ .name = pkg.name, .version = pkg.version, .install_path = ip, .pkg = pkg });
            try added_paths.put(allocator, ip, {});
        }
        // Non-root versions are handled in Phase 4.
    }

    // -------------------------------------------------------------------------
    // Phase 4: Conflict resolution - BFS nesting of alternative versions.
    //
    // Process all hoisted packages (root + previously nested) through a BFS
    // work queue. For each package, check whether the root-elected version of
    // each declared dependency satisfies the required range. If not, find the
    // correct resolved version and install it nested directly under the
    // dependent package, then enqueue that nested package for further checking.
    //
    // This handles arbitrary-depth nesting (e.g. web-resource-inliner →
    // nested htmlparser2@5 → nested entities@2) without the depth-1 limitation.
    // -------------------------------------------------------------------------

    // BFS work queue: packages whose dependency conflicts still need checking.
    // We use a plain ArrayList of HoistedPackage (value copy) so that
    // reallocations of `result` don't affect us.
    var work_queue = std.ArrayList(HoistedPackage).init(allocator);
    defer work_queue.deinit();

    // Seed the queue with all packages hoisted in Phase 3.
    try work_queue.appendSlice(result.items);

    var qi4: usize = 0;
    while (qi4 < work_queue.items.len) {
        const hp = work_queue.items[qi4];
        qi4 += 1;

        var dep_it = hp.pkg.dependencies.iterator();
        while (dep_it.next()) |dep| {
            const dep_name = dep.key_ptr.*;
            const dep_range = dep.value_ptr.*;

            // Determine what version Node.js will find for this dep when
            // walking up from hp's install_path. We approximate this as the
            // root version (the most common case and always the worst-case).
            const root_dep_ver = root_versions.get(dep_name) orelse continue;

            // If root version satisfies the required range, no nesting needed.
            if (semver.satisfies(allocator, root_dep_ver, dep_range)) continue;

            // Root version doesn't satisfy; find the best matching candidate.
            const candidates = name_to_pkgs.get(dep_name) orelse continue;
            var best: ?*const ResolvedPackage = null;
            for (candidates.items) |candidate| {
                if (!semver.satisfies(allocator, candidate.version, dep_range)) continue;
                if (best == null or semver.compareVersions(candidate.version, best.?.version) == .gt) {
                    best = candidate;
                }
            }
            const dep_pkg = best orelse continue;

            // Cycle detection: if dep_name already appears anywhere in the
            // current install_path ancestor chain, Node.js module resolution
            // will already find it by walking up - no further nesting needed.
            // Without this check, cyclic transitive deps create an infinite BFS.
            const cycle_prefix = try std.fmt.allocPrint(allocator, "node_modules/{s}/", .{dep_name});
            defer allocator.free(cycle_prefix);
            const cycle_infix = try std.fmt.allocPrint(allocator, "/node_modules/{s}/", .{dep_name});
            defer allocator.free(cycle_infix);
            const cycle_suffix = try std.fmt.allocPrint(allocator, "/node_modules/{s}", .{dep_name});
            defer allocator.free(cycle_suffix);
            if (std.mem.startsWith(u8, hp.install_path, cycle_prefix) or
                std.mem.indexOf(u8, hp.install_path, cycle_infix) != null or
                std.mem.endsWith(u8, hp.install_path, cycle_suffix))
            {
                continue; // Cycle detected - ancestor already provides this package
            }

            // Install nested under this package's directory.
            const nested_path = try std.fmt.allocPrint(
                allocator,
                "{s}/node_modules/{s}",
                .{ hp.install_path, dep_name },
            );
            if (added_paths.contains(nested_path)) {
                allocator.free(nested_path);
                continue;
            }
            try added_paths.put(allocator, nested_path, {});

            const new_hp = HoistedPackage{
                .name = dep_pkg.name,
                .version = dep_pkg.version,
                .install_path = nested_path,
                .pkg = dep_pkg,
            };
            try result.append(new_hp);
            // Enqueue the newly-nested package so its own deps are checked.
            try work_queue.append(new_hp);
        }
    }

    return result.toOwnedSlice();
}

// ============================================================================
// Internal types
// ============================================================================

/// Tracks how many times a specific (name, version) pair appears in the tree.
const VersionCount = struct {
    name: []const u8,
    version: []const u8,
    count: u32,
};

/// Reasons why a package cannot be hoisted to a higher position.
pub const HoistBlock = enum {
    version_collision,
    peer_dependency,
    nohoist_rule,
    tainted,
};
