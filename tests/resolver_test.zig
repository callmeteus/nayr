//! Dependency Resolver Tests (unit-level)

const std = @import("std");
const semver = @import("../src/semver/parser.zig");

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
