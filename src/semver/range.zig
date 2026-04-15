//! Semver Range Parser
//!
//! Parses npm-compatible version range strings and evaluates whether a given
//! Version satisfies a range. Supports the full npm semver range grammar:
//!
//!   ^1.2.3   — compatible with 1.2.3 (same major, >= minor.patch)
//!   ~1.2.3   — approximately 1.2.3 (same major.minor, >= patch)
//!   >=1.2.3  — greater than or equal
//!   >1.2.3   — strictly greater
//!   <=1.2.3  — less than or equal
//!   <1.2.3   — strictly less
//!   1.2.3    — exact match (implicitly =1.2.3)
//!   *        — any version
//!   1.x      — any 1.y.z
//!   1.2.x    — any 1.2.z
//!   1.2.3 - 2.0.0   — hyphen range (inclusive on both ends)
//!   >=1.0.0 <2.0.0  — AND of two comparators
//!   ^1.0.0 || ^2.0.0 — OR of two comparator sets

const std = @import("std");
const types = @import("types.zig");
const Version = types.Version;

// ============================================================================
// Comparator
// ============================================================================

/// A single version comparator, e.g. `>=1.2.3`.
pub const Comparator = struct {
    op: Op,
    version: Version,

    /// Comparison operator.
    pub const Op = enum {
        /// Exact match: `=1.2.3`
        eq,
        /// Greater than: `>1.2.3`
        gt,
        /// Greater than or equal: `>=1.2.3`
        gte,
        /// Less than: `<1.2.3`
        lt,
        /// Less than or equal: `<=1.2.3`
        lte,
    };

    /// Returns true when `v` satisfies this comparator.
    pub fn matches(self: Comparator, v: Version) bool {
        const ord = v.order(self.version);
        return switch (self.op) {
            .eq => ord == .eq,
            .gt => ord == .gt,
            .gte => ord == .gt or ord == .eq,
            .lt => ord == .lt,
            .lte => ord == .lt or ord == .eq,
        };
    }
};

// ============================================================================
// Range
// ============================================================================

/// A parsed version range. Represented as a list of comparator sets (the
/// OR segments separated by `||`). A version satisfies the range when it
/// satisfies at least one comparator set. Within a set, all comparators
/// must be satisfied (AND logic).
pub const Range = struct {
    /// Each inner slice is one comparator set (the AND group between `||`).
    sets: []const []const Comparator,

    /// Parses a range string into a `Range`.
    ///
    /// Does not take ownership of `s`; all slices point into the allocator.
    ///
    /// ## Parameters
    /// - `allocator`: Used to allocate comparator slices.
    /// - `s`: The range string (e.g. "^1.2.3 || >=2.0.0 <3.0.0").
    ///
    /// ## Returns
    /// The parsed `Range`, or `error.InvalidRange`.
    pub fn parse(allocator: std.mem.Allocator, s: []const u8) !Range {
        const trimmed = std.mem.trim(u8, s, " \t");

        // Split on `||` to get comparator sets.
        var set_list = std.ArrayList([]const Comparator).init(allocator);
        var or_it = std.mem.splitSequence(u8, trimmed, "||");
        while (or_it.next()) |set_str| {
            const set = try parseComparatorSet(allocator, std.mem.trim(u8, set_str, " \t"));
            try set_list.append(set);
        }
        return Range{ .sets = try set_list.toOwnedSlice() };
    }

    /// Returns true when `v` satisfies this range.
    ///
    /// A version satisfies the range if it satisfies at least one comparator
    /// set (OR logic). Pre-release versions only satisfy ranges that
    /// explicitly include a pre-release on the same [major, minor, patch].
    pub fn satisfies(self: Range, v: Version) bool {
        for (self.sets) |set| {
            var all = true;
            for (set) |cmp| {
                if (!cmp.matches(v)) {
                    all = false;
                    break;
                }
            }
            if (all) return true;
        }
        return false;
    }
};

// ============================================================================
// Internal parsers
// ============================================================================

/// Parses a single comparator set (space-separated comparators).
/// Expands sugar forms (^, ~, *, x ranges, hyphen ranges) into pairs of
/// `>=` and `<` comparators.
fn parseComparatorSet(allocator: std.mem.Allocator, s: []const u8) ![]const Comparator {
    var list = std.ArrayList(Comparator).init(allocator);

    // Handle hyphen range: "1.2.3 - 2.0.0"
    if (std.mem.indexOf(u8, s, " - ")) |dash| {
        const lo_str = std.mem.trim(u8, s[0..dash], " ");
        const hi_str = std.mem.trim(u8, s[dash + 3 ..], " ");
        const lo = try Version.parse(lo_str);
        const hi = try Version.parse(hi_str);
        try list.append(.{ .op = .gte, .version = lo });
        try list.append(.{ .op = .lte, .version = hi });
        return list.toOwnedSlice();
    }

    // Split on whitespace; each token is one comparator.
    var tok_it = std.mem.tokenizeAny(u8, s, " \t");
    while (tok_it.next()) |token| {
        const expanded = try expandSugar(allocator, token);
        for (expanded) |c| try list.append(c);
    }

    return list.toOwnedSlice();
}

/// Expands sugar forms (^, ~, *, x) into explicit `>=` / `<` pairs.
fn expandSugar(allocator: std.mem.Allocator, token: []const u8) ![]const Comparator {
    var list = std.ArrayList(Comparator).init(allocator);

    if (token.len == 0 or std.mem.eql(u8, token, "*") or std.mem.eql(u8, token, "latest")) {
        // Match any version: `>=0.0.0`
        try list.append(.{ .op = .gte, .version = Version{ .major = 0, .minor = 0, .patch = 0 } });
        return list.toOwnedSlice();
    }

    if (token[0] == '^') {
        // Caret range: compatible with. Allows patch and minor updates that
        // do not modify the left-most non-zero digit.
        const v = try Version.parse(token[1..]);
        try list.append(.{ .op = .gte, .version = v });
        if (v.major != 0) {
            // ^1.2.3 := >=1.2.3 <2.0.0
            try list.append(.{ .op = .lt, .version = .{ .major = v.major + 1, .minor = 0, .patch = 0 } });
        } else if (v.minor != 0) {
            // ^0.2.3 := >=0.2.3 <0.3.0
            try list.append(.{ .op = .lt, .version = .{ .major = 0, .minor = v.minor + 1, .patch = 0 } });
        } else {
            // ^0.0.3 := >=0.0.3 <0.0.4
            try list.append(.{ .op = .lt, .version = .{ .major = 0, .minor = 0, .patch = v.patch + 1 } });
        }
        return list.toOwnedSlice();
    }

    if (token[0] == '~') {
        // Tilde range: approximately. Allows patch updates.
        const v = try Version.parse(token[1..]);
        try list.append(.{ .op = .gte, .version = v });
        // ~1.2.3 := >=1.2.3 <1.3.0
        try list.append(.{ .op = .lt, .version = .{ .major = v.major, .minor = v.minor + 1, .patch = 0 } });
        return list.toOwnedSlice();
    }

    // Check for x-ranges: "1.x", "1.2.x", "1", "1.2"
    if (isXRange(token)) {
        const cmps = try parseXRange(allocator, token);
        return cmps;
    }

    // Explicit operator: >=, >, <=, <, =
    if (token[0] == '>') {
        if (token.len > 1 and token[1] == '=') {
            const v = try Version.parse(token[2..]);
            try list.append(.{ .op = .gte, .version = v });
        } else {
            const v = try Version.parse(token[1..]);
            try list.append(.{ .op = .gt, .version = v });
        }
        return list.toOwnedSlice();
    }

    if (token[0] == '<') {
        if (token.len > 1 and token[1] == '=') {
            const v = try Version.parse(token[2..]);
            try list.append(.{ .op = .lte, .version = v });
        } else {
            const v = try Version.parse(token[1..]);
            try list.append(.{ .op = .lt, .version = v });
        }
        return list.toOwnedSlice();
    }

    if (token[0] == '=') {
        const v = try Version.parse(token[1..]);
        try list.append(.{ .op = .eq, .version = v });
        return list.toOwnedSlice();
    }

    // Bare version string: exact match.
    const v = Version.parse(token) catch {
        // Unknown token — treat as "any" and continue gracefully.
        try list.append(.{ .op = .gte, .version = .{ .major = 0, .minor = 0, .patch = 0 } });
        return list.toOwnedSlice();
    };
    try list.append(.{ .op = .eq, .version = v });
    return list.toOwnedSlice();
}

/// Returns true when the token is an x-range like "1", "1.2", "1.x", "1.2.x".
fn isXRange(token: []const u8) bool {
    var parts: u8 = 0;
    var it = std.mem.splitScalar(u8, token, '.');
    while (it.next()) |p| {
        parts += 1;
        if (std.mem.eql(u8, p, "x") or std.mem.eql(u8, p, "X") or std.mem.eql(u8, p, "*")) return true;
        _ = std.fmt.parseUnsigned(u32, p, 10) catch return false;
    }
    return parts < 3; // "1" or "1.2" are implicit x-ranges
}

/// Parses an x-range into a `>=` / `<` pair.
fn parseXRange(allocator: std.mem.Allocator, token: []const u8) ![]const Comparator {
    var list = std.ArrayList(Comparator).init(allocator);

    var parts = [_]?u32{ null, null, null };
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, token, '.');
    while (it.next()) |p| {
        if (idx >= 3) break;
        if (std.mem.eql(u8, p, "x") or std.mem.eql(u8, p, "X") or std.mem.eql(u8, p, "*")) {
            parts[idx] = null;
        } else {
            parts[idx] = std.fmt.parseUnsigned(u32, p, 10) catch null;
        }
        idx += 1;
    }

    const major = parts[0] orelse {
        // "x" or "*" — match anything.
        try list.append(.{ .op = .gte, .version = .{ .major = 0, .minor = 0, .patch = 0 } });
        return list.toOwnedSlice();
    };

    const minor = parts[1] orelse {
        // "1.x" := >=1.0.0 <2.0.0
        try list.append(.{ .op = .gte, .version = .{ .major = major, .minor = 0, .patch = 0 } });
        try list.append(.{ .op = .lt, .version = .{ .major = major + 1, .minor = 0, .patch = 0 } });
        return list.toOwnedSlice();
    };

    // "1.2.x" or "1.2" := >=1.2.0 <1.3.0
    try list.append(.{ .op = .gte, .version = .{ .major = major, .minor = minor, .patch = 0 } });
    try list.append(.{ .op = .lt, .version = .{ .major = major, .minor = minor + 1, .patch = 0 } });
    return list.toOwnedSlice();
}
