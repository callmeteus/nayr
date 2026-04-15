//! Nohoist Resolution
//!
//! Yarn Classic nohoist prevents specific packages from being hoisted to the
//! root node_modules. Instead they remain nested under each workspace's own
//! node_modules.
//!
//! Nohoist patterns use glob syntax and are matched against the "virtual path"
//! of a package in the dependency tree:
//!   `/_project_/<workspace-name>/<package-name>[/<nested-dep>...]`
//!
//! Examples:
//!   `**/react-native/**` - never hoist any react-native dep anywhere
//!   `@scope/pkg`         - never hoist this specific scoped package

const std = @import("std");
const fs_util = @import("../util/fs.zig");

// ============================================================================
// NohoistChecker
// ============================================================================

/// Evaluates nohoist rules for the hoisting algorithm.
pub const NohoistChecker = struct {
    /// The raw nohoist glob patterns from the root package.json.
    patterns: []const []const u8,

    /// Creates a checker from the given patterns.
    pub fn init(patterns: []const []const u8) NohoistChecker {
        return .{ .patterns = patterns };
    }

    /// Returns true when the given virtual path matches any nohoist pattern.
    ///
    /// The virtual path format is:
    ///   `/_project_/<workspace>/<package>[/<nested>...]`
    ///
    /// ## Parameters
    /// - `virtual_path`: The dependency's virtual path in the tree.
    ///
    /// ## Returns
    /// `true` = this package must NOT be hoisted past its workspace boundary.
    pub fn shouldNohoist(self: *const NohoistChecker, virtual_path: []const u8) bool {
        for (self.patterns) |pattern| {
            if (fs_util.globMatch(pattern, virtual_path)) return true;
        }
        return false;
    }
};

// ============================================================================
// Virtual path builder
// ============================================================================

/// Builds the virtual path for a package in the dependency tree.
///
/// ## Parameters
/// - `allocator`: Scratch allocator.
/// - `workspace_name`: The workspace that declared this dependency.
/// - `package_name`: The package being evaluated for hoisting.
/// - `ancestors`: Additional ancestor package names in the dependency chain.
///
/// ## Returns
/// A virtual path like `/_project_/lm/react/react-dom`. Caller must free.
pub fn buildVirtualPath(
    allocator: std.mem.Allocator,
    workspace_name: []const u8,
    package_name: []const u8,
    ancestors: []const []const u8,
) ![]const u8 {
    var parts = std.ArrayList([]const u8).init(allocator);
    defer parts.deinit();

    try parts.append("_project_");
    try parts.append(workspace_name);
    for (ancestors) |a| try parts.append(a);
    try parts.append(package_name);

    return std.mem.join(allocator, "/", parts.items);
}
