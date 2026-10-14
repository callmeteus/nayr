//! Filesystem Utility Tests
//!
//! Covers `globExpand`'s handling of glob patterns as they appear in real
//! `package.json` `workspaces` fields, including the `./`-prefixed form used
//! by luckymaker (`"./packages/*"`) which previously matched zero entries.

const std = @import("std");
const fs_util = @import("../src/util/fs.zig");

/// Builds a temporary directory with two sub-packages under `packages/`,
/// mirroring a minimal monorepo layout.
fn makeFixture(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    try tmp.dir.makePath("packages/cli");
    try tmp.dir.makePath("packages/foo");
    try tmp.dir.writeFile(.{ .sub_path = "packages/cli/package.json", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "packages/foo/package.json", .data = "{}" });
    return tmp.dir.realpathAlloc(allocator, ".");
}

test "globExpand: matches packages/* without a leading dot-slash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try makeFixture(allocator, &tmp);
    defer allocator.free(root);

    const matches = try fs_util.globExpand(allocator, root, "packages/*");
    defer {
        for (matches) |m| allocator.free(m);
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.len);
}

test "globExpand: matches ./packages/* the same way as packages/*" {
    // Regression test: luckymaker's package.json declares workspace globs
    // with a leading "./" (e.g. "./packages/*"). Before the fix, globExpand
    // compared this literal prefix against real directory names character by
    // character and never matched, silently discovering zero workspaces.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try makeFixture(allocator, &tmp);
    defer allocator.free(root);

    const matches = try fs_util.globExpand(allocator, root, "./packages/*");
    defer {
        for (matches) |m| allocator.free(m);
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.len);
}

test "globExpand: no match for a non-existent glob" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try makeFixture(allocator, &tmp);
    defer allocator.free(root);

    const matches = try fs_util.globExpand(allocator, root, "./missing/*");
    defer {
        for (matches) |m| allocator.free(m);
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 0), matches.len);
}
