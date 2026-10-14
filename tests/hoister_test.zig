//! Hoisting Algorithm Tests

const std = @import("std");
const nohoist = @import("../src/workspace/nohoist.zig");
const hoister = @import("../src/core/hoister.zig");
const resolver = @import("../src/core/resolver.zig");
const ResolvedPackage = resolver.ResolvedPackage;

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

// Regression test: a workspace package (e.g. luckymaker's `packages/cli`)
// declaring a dependency range that conflicts with the root-elected version
// must get that dependency nested under its own node_modules, not silently
// resolve to the wrong version via Node's upward module lookup. This covers
// the fix where workspace `ResolvedPackage` entries previously carried an
// empty `dependencies` map, so Phase 4 conflict resolution never saw their
// declared ranges (e.g. `@luckymaker/cli` declaring `axios@^1.15.2` while the
// root pins `axios@^0.31.1`).
test "hoist: nests a workspace package's dependency when root version conflicts" {
    const allocator = std.testing.allocator;

    var cli_deps = std.StringHashMapUnmanaged([]const u8){};
    defer cli_deps.deinit(allocator);
    try cli_deps.put(allocator, "axios", "^1.15.2");

    var packages = std.StringHashMapUnmanaged(ResolvedPackage){};
    defer packages.deinit(allocator);

    try packages.put(allocator, "@luckymaker/cli@1.0.0", .{
        .name = "@luckymaker/cli",
        .version = "1.0.0",
        .tarball_url = "",
        .integrity = "",
        .registry = "",
        .is_workspace = true,
        .is_git = false,
        .dependencies = cli_deps,
        .optional_dependencies = .{},
    });
    try packages.put(allocator, "axios@0.31.1", .{
        .name = "axios",
        .version = "0.31.1",
        .tarball_url = "https://registry.npmjs.org/axios/-/axios-0.31.1.tgz",
        .integrity = "sha512-root",
        .registry = "",
        .is_workspace = false,
        .is_git = false,
        .dependencies = .{},
        .optional_dependencies = .{},
    });
    try packages.put(allocator, "axios@1.15.2", .{
        .name = "axios",
        .version = "1.15.2",
        .tarball_url = "https://registry.npmjs.org/axios/-/axios-1.15.2.tgz",
        .integrity = "sha512-cli",
        .registry = "",
        .is_workspace = false,
        .is_git = false,
        .dependencies = .{},
        .optional_dependencies = .{},
    });

    var root_dep_ranges = std.StringHashMapUnmanaged([]const u8){};
    defer root_dep_ranges.deinit(allocator);
    try root_dep_ranges.put(allocator, "axios", "^0.31.1");

    const checker = nohoist.NohoistChecker.init(&.{});

    const hoisted = try hoister.hoist(allocator, &packages, &checker, &root_dep_ranges);
    defer {
        for (hoisted) |h| allocator.free(h.install_path);
        allocator.free(hoisted);
    }

    var root_axios_found = false;
    var nested_axios_found = false;
    for (hoisted) |h| {
        if (std.mem.eql(u8, h.name, "axios") and std.mem.eql(u8, h.version, "0.31.1")) {
            try std.testing.expectEqualStrings("node_modules/axios", h.install_path);
            root_axios_found = true;
        }
        if (std.mem.eql(u8, h.name, "axios") and std.mem.eql(u8, h.version, "1.15.2")) {
            try std.testing.expectEqualStrings("node_modules/@luckymaker/cli/node_modules/axios", h.install_path);
            nested_axios_found = true;
        }
    }

    try std.testing.expect(root_axios_found);
    try std.testing.expect(nested_axios_found);
}
