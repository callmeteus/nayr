//! Integrity Fast-Path Tests

const std = @import("std");
const integrity = @import("../src/core/integrity.zig");

/// Builds a minimal monorepo fixture: a root `package.json` declaring one
/// workspace glob, a `packages/foo/package.json`, and an empty `node_modules/`.
fn makeFixture(tmp: *std.testing.TmpDir) !void {
    try tmp.dir.makePath("packages/foo");
    try tmp.dir.makePath("node_modules");
    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"root","workspaces":["packages/*"]}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "packages/foo/package.json",
        .data =
        \\{"name":"foo","dependencies":{}}
        ,
    });
}

test "isUpToDate: true right after save, with no changes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFixture(&tmp);

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try integrity.save(allocator, root);
    try std.testing.expect(try integrity.isUpToDate(allocator, root));
}

test "isUpToDate: false after a workspace package.json changes" {
    // Regression test: editing a workspace manifest (e.g. adding a dependency
    // to packages/cli/package.json in a monorepo) previously left the fast-path
    // hash unchanged, because computeHash only read the root package.json.
    // `nayr` would report "already up to date" and silently skip resolving the
    // new dependency.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFixture(&tmp);

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try integrity.save(allocator, root);
    try std.testing.expect(try integrity.isUpToDate(allocator, root));

    // Simulate adding a dependency to the workspace package's manifest.
    try tmp.dir.writeFile(.{
        .sub_path = "packages/foo/package.json",
        .data =
        \\{"name":"foo","dependencies":{"chalk":"^5.3.0"}}
        ,
    });

    try std.testing.expect(!try integrity.isUpToDate(allocator, root));
}

test "isUpToDate: false after a workspace package is removed entirely" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFixture(&tmp);

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try integrity.save(allocator, root);
    try std.testing.expect(try integrity.isUpToDate(allocator, root));

    try tmp.dir.deleteTree("packages/foo");

    try std.testing.expect(!try integrity.isUpToDate(allocator, root));
}
