//! Hoisting Algorithm Tests

const std = @import("std");
const nohoist = @import("../src/workspace/nohoist.zig");

test "nohoist: star pattern matches any" {
    const checker = nohoist.NohoistChecker.init(&[_][]const u8{"**"});
    try std.testing.expect(checker.shouldNohoist("_project_/frontend/react"));
    try std.testing.expect(checker.shouldNohoist("_project_/backend/lodash"));
}

test "nohoist: specific package" {
    const checker = nohoist.NohoistChecker.init(&[_][]const u8{"react"});
    try std.testing.expect(checker.shouldNohoist("react"));
    try std.testing.expect(!checker.shouldNohoist("react-dom"));
}

test "nohoist: no patterns" {
    const checker = nohoist.NohoistChecker.init(&.{});
    try std.testing.expect(!checker.shouldNohoist("_project_/frontend/react"));
}

test "virtual path builder" {
    const allocator = std.testing.allocator;
    const path = try nohoist.buildVirtualPath(
        allocator,
        "frontend",
        "react",
        &.{},
    );
    defer allocator.free(path);
    try std.testing.expectEqualStrings("_project_/frontend/react", path);
}
