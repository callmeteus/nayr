//! Semantic Versioning Types
//!
//! Core types for SemVer 2.0.0 (https://semver.org). Used throughout
//! the resolver and lockfile modules.

const std = @import("std");

// ============================================================================
// Version
// ============================================================================

/// A parsed semantic version: `major.minor.patch[-prerelease][+build]`.
///
/// Examples: `1.2.3`, `2.0.0-beta.1`, `1.0.0+git.abc123`
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// Pre-release identifier, e.g. "beta.1", "rc.2". Empty slice = stable.
    pre: []const u8 = "",
    /// Build metadata — ignored in comparisons per SemVer spec.
    build: []const u8 = "",

    /// Parses a version string. Does not allocate; slices point into `s`.
    ///
    /// ## Parameters
    /// - `s`: The version string to parse (e.g. "1.2.3-beta.1+build.42").
    ///
    /// ## Returns
    /// The parsed `Version`, or `error.InvalidVersion` if the string is
    /// not a valid SemVer version.
    pub fn parse(s: []const u8) !Version {
        var rest = s;

        // Strip a leading 'v' that some packages emit (e.g. "v1.2.3").
        if (rest.len > 0 and rest[0] == 'v') rest = rest[1..];

        // Split off build metadata first (+), then pre-release (-).
        var build: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
            build = rest[plus + 1 ..];
            rest = rest[0..plus];
        }

        var pre: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
            pre = rest[dash + 1 ..];
            rest = rest[0..dash];
        }

        // Parse the numeric triplet major.minor.patch.
        var it = std.mem.splitScalar(u8, rest, '.');
        const major = try parseU32(it.next() orelse return error.InvalidVersion);
        const minor = try parseU32(it.next() orelse return error.InvalidVersion);
        const patch = try parseU32(it.next() orelse return error.InvalidVersion);

        return Version{ .major = major, .minor = minor, .patch = patch, .pre = pre, .build = build };
    }

    /// Compares two versions. Returns:
    ///   - `.lt` if self < other
    ///   - `.eq` if self == other (build metadata ignored)
    ///   - `.gt` if self > other
    ///
    /// Pre-release versions have lower precedence than the release version:
    /// `1.0.0-alpha < 1.0.0`.
    pub fn order(self: Version, other: Version) std.math.Order {
        // Compare numeric components first.
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        if (self.patch != other.patch) return std.math.order(self.patch, other.patch);

        // A pre-release version is lower than the release version.
        if (self.pre.len == 0 and other.pre.len > 0) return .gt;
        if (self.pre.len > 0 and other.pre.len == 0) return .lt;
        if (self.pre.len > 0 and other.pre.len > 0) {
            return comparePreRelease(self.pre, other.pre);
        }
        return .eq;
    }

    /// Returns true when `self` is strictly less than `other`.
    pub fn lt(self: Version, other: Version) bool {
        return self.order(other) == .lt;
    }

    /// Returns true when `self` equals `other` (build metadata ignored).
    pub fn eql(self: Version, other: Version) bool {
        return self.order(other) == .eq;
    }

    /// Formats the version as a string (without build metadata).
    pub fn format(self: Version, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        if (self.pre.len > 0) try writer.print("-{s}", .{self.pre});
    }
};

// ============================================================================
// Internal helpers
// ============================================================================

/// Parses a string as a u32, returning `error.InvalidVersion` on failure.
fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseUnsigned(u32, s, 10) catch error.InvalidVersion;
}

/// Compares two pre-release identifier strings per SemVer spec:
///   - Numeric identifiers have lower precedence than alphanumeric.
///   - Numeric identifiers are compared as integers.
///   - Alphanumeric identifiers are compared lexically.
///   - A larger set of fields has higher precedence.
fn comparePreRelease(a: []const u8, b: []const u8) std.math.Order {
    var a_it = std.mem.splitScalar(u8, a, '.');
    var b_it = std.mem.splitScalar(u8, b, '.');

    while (true) {
        const a_field = a_it.next();
        const b_field = b_it.next();

        if (a_field == null and b_field == null) return .eq;
        if (a_field == null) return .lt; // fewer fields = lower precedence
        if (b_field == null) return .gt;

        const af = a_field.?;
        const bf = b_field.?;

        const a_num = std.fmt.parseUnsigned(u64, af, 10) catch null;
        const b_num = std.fmt.parseUnsigned(u64, bf, 10) catch null;

        if (a_num != null and b_num != null) {
            // Both numeric: compare as integers.
            if (a_num.? != b_num.?) return std.math.order(a_num.?, b_num.?);
        } else if (a_num != null) {
            // Numeric < alphanumeric.
            return .lt;
        } else if (b_num != null) {
            return .gt;
        } else {
            // Both alphanumeric: lexical comparison.
            const cmp = std.mem.order(u8, af, bf);
            if (cmp != .eq) return cmp;
        }
    }
}
