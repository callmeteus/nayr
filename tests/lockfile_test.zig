//! Lockfile Parser Tests

const std = @import("std");
const yarn_v1 = @import("../src/lockfile/yarn_v1.zig");
const nayr_fmt = @import("../src/lockfile/nayr_format.zig");
const lockfile_types = @import("../src/lockfile/types.zig");

test "yarn v1 parse: simple entry" {
    const allocator = std.testing.allocator;

    const src =
        \\# yarn lockfile v1
        \\
        \\"lodash@^4.17.0":
        \\  version "4.17.21"
        \\  resolved "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz#abc123"
        \\  integrity sha512-deadbeef
        \\
    ;

    var lock = try yarn_v1.parseSlice(allocator, src);
    defer lock.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), lock.entries.len);
    const entry = lock.entries[0];
    try std.testing.expectEqualStrings("4.17.21", entry.version);
    // Hash fragment should be stripped from resolved URL.
    try std.testing.expectEqualStrings(
        "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz",
        entry.resolved,
    );
    try std.testing.expectEqualStrings("sha512-deadbeef", entry.integrity);
}

test "yarn v1 parse: multi-pattern entry" {
    const allocator = std.testing.allocator;

    const src =
        \\# yarn lockfile v1
        \\
        \\"lodash@^4.17.0", "lodash@^4.17.21":
        \\  version "4.17.21"
        \\  resolved "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz"
        \\  integrity sha512-deadbeef
        \\
    ;

    var lock = try yarn_v1.parseSlice(allocator, src);
    defer lock.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), lock.entries.len);
    try std.testing.expectEqual(@as(usize, 2), lock.entries[0].patterns.len);
}

test "nayr format: round-trip" {
    const allocator = std.testing.allocator;

    const src =
        \\# nayr lockfile v1
        \\
        \\lodash@^4.17.0, lodash@^4.17.21:
        \\  version: 4.17.21
        \\  resolved: https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz
        \\  integrity: sha512-deadbeef
        \\
    ;

    var lock = try nayr_fmt.parseSlice(allocator, src);
    defer lock.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), lock.entries.len);
    const e = lock.entries[0];
    try std.testing.expectEqualStrings("4.17.21", e.version);
    try std.testing.expectEqualStrings(
        "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz",
        e.resolved,
    );
}

test "lockfile pattern map lookup" {
    const allocator = std.testing.allocator;

    const src =
        \\# nayr lockfile v1
        \\
        \\lodash@^4.0.0:
        \\  version: 4.17.21
        \\  resolved: https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz
        \\
    ;

    var lock = try nayr_fmt.parseSlice(allocator, src);
    defer lock.deinit(allocator);

    const entry = lock.get("lodash@^4.0.0");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("4.17.21", entry.?.version);

    const missing = lock.get("lodash@^5.0.0");
    try std.testing.expect(missing == null);
}

test "lockfile semanticEqual: identical parsed lockfiles" {
    const allocator = std.testing.allocator;

    const src =
        \\# yarn lockfile v1
        \\
        \\"lodash@^4.17.0", "lodash@^4.17.21":
        \\  version "4.17.21"
        \\  resolved "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz"
        \\  integrity sha512-deadbeef
        \\
    ;

    var lock_a = try yarn_v1.parseSlice(allocator, src);
    defer lock_a.deinit(allocator);
    var lock_b = try yarn_v1.parseSlice(allocator, src);
    defer lock_b.deinit(allocator);

    try std.testing.expect(lockfile_types.Lockfile.semanticEqual(&lock_a, &lock_b));
}

test "lockfile semanticEqual: version mismatch" {
    const allocator = std.testing.allocator;

    const src_a =
        \\# yarn lockfile v1
        \\
        \\"lodash@^4.17.0":
        \\  version "4.17.21"
        \\
    ;
    const src_b =
        \\# yarn lockfile v1
        \\
        \\"lodash@^4.17.0":
        \\  version "4.18.0"
        \\
    ;

    var lock_a = try yarn_v1.parseSlice(allocator, src_a);
    defer lock_a.deinit(allocator);
    var lock_b = try yarn_v1.parseSlice(allocator, src_b);
    defer lock_b.deinit(allocator);

    try std.testing.expect(!lockfile_types.Lockfile.semanticEqual(&lock_a, &lock_b));
}
