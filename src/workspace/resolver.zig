//! Workspace Resolver
//!
//! Resolves cross-workspace dependencies. When package A declares a
//! dependency on `@luckymaker/shared: "^1.0.0"` and `@luckymaker/shared` is
//! a workspace package at a compatible version, the workspace copy is used
//! directly (symlinked) instead of being downloaded from the registry.

const std = @import("std");
const semver = @import("../semver/parser.zig");
const discovery = @import("discovery.zig");

// ============================================================================
// WorkspaceResolver
// ============================================================================

/// Resolves workspace inter-dependencies.
pub const WorkspaceResolver = struct {
    /// Map of package name → workspace package.
    packages: std.StringHashMapUnmanaged(*const discovery.WorkspacePackage),
    allocator: std.mem.Allocator,

    /// Builds a resolver from the discovered workspace packages.
    pub fn init(
        allocator: std.mem.Allocator,
        packages: []const discovery.WorkspacePackage,
    ) !WorkspaceResolver {
        var map = std.StringHashMapUnmanaged(*const discovery.WorkspacePackage){};
        for (packages) |*pkg| {
            const name = pkg.manifest.name orelse continue;
            try map.put(allocator, name, pkg);
        }
        return .{ .packages = map, .allocator = allocator };
    }

    pub fn deinit(self: *WorkspaceResolver) void {
        self.packages.deinit(self.allocator);
    }

    /// Returns the workspace package that satisfies the given dependency, or
    /// `null` if no workspace satisfies it (fall through to registry lookup).
    ///
    /// ## Parameters
    /// - `name`: The package name to look up.
    /// - `range`: The version range to match against.
    ///
    /// ## Returns
    /// A pointer to the matching `WorkspacePackage`, or `null`.
    pub fn resolve(
        self: *const WorkspaceResolver,
        name: []const u8,
        range: []const u8,
    ) ?*const discovery.WorkspacePackage {
        const pkg = self.packages.get(name) orelse return null;
        const version = pkg.manifest.version orelse return null;

        // `*` and `"workspace:*"` always match workspace packages.
        if (std.mem.eql(u8, range, "*") or
            std.mem.eql(u8, range, "workspace:*") or
            std.mem.eql(u8, range, "workspace:^") or
            std.mem.eql(u8, range, "workspace:~"))
        {
            return pkg;
        }

        // Strip `workspace:` prefix if present (Yarn Berry syntax, sometimes used).
        const clean_range = if (std.mem.startsWith(u8, range, "workspace:"))
            range["workspace:".len..]
        else
            range;

        return if (semver.satisfies(self.allocator, version, clean_range)) pkg else null;
    }
};
