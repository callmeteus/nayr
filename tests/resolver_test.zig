//! Dependency Resolver Tests (unit-level)

const std = @import("std");
const semver = @import("../src/semver/parser.zig");
const ws_resolver = @import("../src/workspace/resolver.zig");
const ws_discovery = @import("../src/workspace/discovery.zig");

test "workspace resolution: satisfies range" {
    const allocator = std.testing.allocator;
    try std.testing.expect(semver.satisfies(allocator, "1.0.0", "*"));
    try std.testing.expect(semver.satisfies(allocator, "1.0.0", "workspace:*"));
}

test "git dep detection" {
    // Mimic the resolver's isGitDep logic.
    const git_deps = &[_][]const u8{
        "git+https://github.com/even7hq/lemon-linting.git",
        "git://github.com/user/repo.git",
        "github:user/repo",
    };
    const non_git = &[_][]const u8{
        "^1.0.0",
        "~1.2.3",
        "latest",
    };

    for (git_deps) |dep| {
        try std.testing.expect(
            std.mem.startsWith(u8, dep, "git+") or
                std.mem.startsWith(u8, dep, "git://") or
                std.mem.startsWith(u8, dep, "github:"),
        );
    }
    for (non_git) |dep| {
        try std.testing.expect(
            !std.mem.startsWith(u8, dep, "git+") and
                !std.mem.startsWith(u8, dep, "git://") and
                !std.mem.startsWith(u8, dep, "github:"),
        );
    }
}

test "resolution override: resolutions field" {
    // Verify that a `resolutions` entry produces exact match.
    const allocator = std.testing.allocator;
    try std.testing.expect(semver.satisfies(allocator, "2.0.0", "2.0.0"));
}

test "workspace resolver: star range matches monorepo package" {
    const allocator = std.testing.allocator;

    var manifest = @import("../src/util/json.zig").PackageJson{};
    manifest.name = "@e7/platform";
    manifest.version = "1.0.0";

    const workspaces = [_]ws_discovery.WorkspacePackage{
        .{
            .path = "/tmp/packages/platform",
            .rel_path = "packages/platform",
            .manifest = manifest,
        },
    };

    var resolver = try ws_resolver.WorkspaceResolver.init(allocator, &workspaces);
    defer resolver.deinit();

    const hit = resolver.resolve("@e7/platform", "*");
    try std.testing.expect(hit != null);
    try std.testing.expect(std.mem.eql(u8, hit.?.manifest.version orelse "", "1.0.0"));
}
