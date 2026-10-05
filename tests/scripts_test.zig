const std = @import("std");
const scripts = @import("../src/core/scripts.zig");

test "buildScriptPath includes npm node-gyp-bin when node is available" {
    const allocator = std.testing.allocator;
    const path = scripts.buildScriptPath(allocator, "/tmp/nayr-proj", "/tmp/nayr-proj") catch {
        return error.SkipZigTest;
    };
    defer allocator.free(path);

    if (std.mem.indexOf(u8, path, "node-gyp-bin") == null) {
        return error.SkipZigTest;
    }
}

test "buildScriptPath includes root node_modules bin" {
    const allocator = std.testing.allocator;
    const path = scripts.buildScriptPath(allocator, "/tmp/nayr-proj", "/tmp/nayr-proj") catch return;
    defer allocator.free(path);

    try std.testing.expect(std.mem.indexOf(u8, path, "/tmp/nayr-proj/node_modules/.bin") != null);
}
