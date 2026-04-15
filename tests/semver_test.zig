//! Semver Engine Tests

const std = @import("std");
const semver = @import("../src/semver/parser.zig");
const Version = semver.Version;
const Range = semver.Range;

test "version parse: simple" {
    const v = try Version.parse("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 2), v.minor);
    try std.testing.expectEqual(@as(u32, 3), v.patch);
    try std.testing.expectEqualStrings("", v.pre);
}

test "version parse: with v prefix" {
    const v = try Version.parse("v2.0.0");
    try std.testing.expectEqual(@as(u32, 2), v.major);
}

test "version parse: prerelease" {
    const v = try Version.parse("1.0.0-beta.1");
    try std.testing.expectEqualStrings("beta.1", v.pre);
}

test "version order: basic" {
    const a = try Version.parse("1.2.3");
    const b = try Version.parse("1.2.4");
    try std.testing.expect(a.lt(b));
    try std.testing.expect(!b.lt(a));
}

test "version order: prerelease < release" {
    const pre = try Version.parse("1.0.0-alpha");
    const rel = try Version.parse("1.0.0");
    try std.testing.expect(pre.lt(rel));
}

test "satisfies: caret" {
    const allocator = std.testing.allocator;
    try std.testing.expect(semver.satisfies(allocator, "1.2.3", "^1.0.0"));
    try std.testing.expect(semver.satisfies(allocator, "1.99.0", "^1.0.0"));
    try std.testing.expect(!semver.satisfies(allocator, "2.0.0", "^1.0.0"));
    try std.testing.expect(!semver.satisfies(allocator, "0.9.0", "^1.0.0"));
}

test "satisfies: tilde" {
    const allocator = std.testing.allocator;
    try std.testing.expect(semver.satisfies(allocator, "1.2.5", "~1.2.3"));
    try std.testing.expect(!semver.satisfies(allocator, "1.3.0", "~1.2.3"));
}

test "satisfies: gte" {
    const allocator = std.testing.allocator;
    try std.testing.expect(semver.satisfies(allocator, "2.0.0", ">=1.0.0"));
    try std.testing.expect(!semver.satisfies(allocator, "0.9.9", ">=1.0.0"));
}

test "satisfies: exact" {
    const allocator = std.testing.allocator;
    try std.testing.expect(semver.satisfies(allocator, "1.2.3", "1.2.3"));
    try std.testing.expect(!semver.satisfies(allocator, "1.2.4", "1.2.3"));
}

test "satisfies: star" {
    const allocator = std.testing.allocator;
    try std.testing.expect(semver.satisfies(allocator, "99.0.0", "*"));
    try std.testing.expect(semver.satisfies(allocator, "0.0.1", "*"));
}

test "satisfies: or" {
    const allocator = std.testing.allocator;
    try std.testing.expect(semver.satisfies(allocator, "1.0.0", "^1.0.0 || ^2.0.0"));
    try std.testing.expect(semver.satisfies(allocator, "2.5.0", "^1.0.0 || ^2.0.0"));
    try std.testing.expect(!semver.satisfies(allocator, "3.0.0", "^1.0.0 || ^2.0.0"));
}

test "maxSatisfying: basic" {
    const allocator = std.testing.allocator;
    const versions = &[_][]const u8{ "1.0.0", "1.2.3", "1.5.0", "2.0.0" };
    const best = semver.maxSatisfying(allocator, versions, "^1.0.0", null);
    try std.testing.expectEqualStrings("1.5.0", best.?);
}

test "maxSatisfying: prefers latest dist-tag" {
    const allocator = std.testing.allocator;
    const versions = &[_][]const u8{ "1.0.0", "1.2.3", "1.5.0" };
    const best = semver.maxSatisfying(allocator, versions, "^1.0.0", "1.2.3");
    try std.testing.expectEqualStrings("1.2.3", best.?);
}

test "maxSatisfying: no match" {
    const allocator = std.testing.allocator;
    const versions = &[_][]const u8{ "2.0.0", "3.0.0" };
    const best = semver.maxSatisfying(allocator, versions, "^1.0.0", null);
    try std.testing.expect(best == null);
}

test "x-range: 1.x" {
    const allocator = std.testing.allocator;
    try std.testing.expect(semver.satisfies(allocator, "1.5.0", "1.x"));
    try std.testing.expect(!semver.satisfies(allocator, "2.0.0", "1.x"));
}

test "hyphen range" {
    const allocator = std.testing.allocator;
    try std.testing.expect(semver.satisfies(allocator, "1.5.0", "1.0.0 - 2.0.0"));
    try std.testing.expect(!semver.satisfies(allocator, "0.9.0", "1.0.0 - 2.0.0"));
}
