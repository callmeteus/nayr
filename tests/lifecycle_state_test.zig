//! Lifecycle state cache tests

const std = @import("std");
const lifecycle_state = @import("../src/core/lifecycle_state.zig");
const resolver = @import("../src/core/resolver.zig");
const hoister = @import("../src/core/hoister.zig");

test "computeFingerprint: changes when integrity changes" {
    const allocator = std.testing.allocator;

    var pkg_a = resolver.ResolvedPackage{
        .name = "lodash",
        .version = "4.17.21",
        .tarball_url = "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz",
        .integrity = "sha512-aaa",
        .registry = "https://registry.npmjs.org/",
        .is_workspace = false,
        .is_git = false,
        .dependencies = .{},
        .optional_dependencies = .{},
    };
    var pkg_b = pkg_a;
    pkg_b.integrity = "sha512-bbb";

    const hp_a = hoister.HoistedPackage{
        .name = "lodash",
        .version = "4.17.21",
        .install_path = "node_modules/lodash",
        .pkg = &pkg_a,
    };
    const hp_b = hoister.HoistedPackage{
        .name = "lodash",
        .version = "4.17.21",
        .install_path = "node_modules/lodash",
        .pkg = &pkg_b,
    };

    const fp_a = try lifecycle_state.computeFingerprint(allocator, hp_a);
    defer allocator.free(fp_a);
    const fp_b = try lifecycle_state.computeFingerprint(allocator, hp_b);
    defer allocator.free(fp_b);

    try std.testing.expect(!std.mem.eql(u8, fp_a, fp_b));
}

test "State: markComplete and isComplete round-trip" {
    const allocator = std.testing.allocator;

    var state = lifecycle_state.State{ .completed = .{} };
    defer state.deinit(allocator);

    try state.markComplete(allocator, "node_modules/foo", "abc123");
    try std.testing.expect(state.isComplete("node_modules/foo", "abc123"));
    try std.testing.expect(!state.isComplete("node_modules/foo", "other"));
}
