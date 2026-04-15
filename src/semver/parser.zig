//! Semver Engine - Public API
//!
//! Provides high-level functions over the semver types and range modules.
//! This is the entry point imported by the resolver.

const std = @import("std");
const types = @import("types.zig");
const range_mod = @import("range.zig");

pub const Version = types.Version;
pub const Range = range_mod.Range;
pub const Comparator = range_mod.Comparator;

/// Returns true when `version` satisfies `range`.
///
/// This is the fundamental predicate used during dependency resolution.
///
/// ## Parameters
/// - `allocator`: Scratch allocator for range parsing (freed before return).
/// - `version_str`: Version string to test (e.g. "1.2.3").
/// - `range_str`: Range string to test against (e.g. "^1.0.0").
pub fn satisfies(allocator: std.mem.Allocator, version_str: []const u8, range_str: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = Version.parse(version_str) catch return false;
    const r = Range.parse(a, range_str) catch return false;
    return r.satisfies(v);
}

/// Returns the highest version from `versions` that satisfies `range_str`.
///
/// Implements the npm convention: if `dist-tags.latest` satisfies the range
/// it is preferred even if a newer version also satisfies it.
///
/// ## Parameters
/// - `allocator`: Scratch allocator for range parsing.
/// - `versions`: Slice of version strings to consider.
/// - `range_str`: Range string (e.g. "^1.0.0").
/// - `latest`: Optional dist-tag "latest" version to prefer.
///
/// ## Returns
/// The best matching version string, or `null` if nothing matches.
pub fn maxSatisfying(
    allocator: std.mem.Allocator,
    versions: []const []const u8,
    range_str: []const u8,
    latest: ?[]const u8,
) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = Range.parse(a, range_str) catch return null;

    // If "latest" satisfies the range, prefer it (npm convention).
    if (latest) |lat| {
        if (Version.parse(lat)) |lv| {
            if (r.satisfies(lv)) return lat;
        } else |_| {}
    }

    var best: ?Version = null;
    var best_str: ?[]const u8 = null;

    for (versions) |vs| {
        const v = Version.parse(vs) catch continue;
        if (!r.satisfies(v)) continue;
        if (best == null or best.?.lt(v)) {
            best = v;
            best_str = vs;
        }
    }

    return best_str;
}

/// Compares two version strings.
///
/// ## Returns
/// - `.lt` if a < b
/// - `.eq` if a == b
/// - `.gt` if a > b
/// - `.lt` on parse error (graceful degradation)
pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    const va = Version.parse(a) catch return .lt;
    const vb = Version.parse(b) catch return .gt;
    return va.order(vb);
}
