//! Tests for `IoTrace` (missing-path reporting for CLI errors).

const std = @import("std");
const IoTrace = @import("../src/util/io_trace.zig").IoTrace;

test "IoTrace record and take" {
    IoTrace.clear();
    IoTrace.recordMissingPath("/tmp/example-missing.json");
    const p = IoTrace.takeMissingPath() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/tmp/example-missing.json", p);
    try std.testing.expect(IoTrace.takeMissingPath() == null);
}
