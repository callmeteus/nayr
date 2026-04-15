//! nayr test runner
//!
//! Root file for the test suite. Imports all test sub-files so that `zig build
//! test` discovers every test block in the project.
//!
//! The module root for tests is the workspace root, so test sub-files may use
//! `@import("src/...")` to access source modules.

comptime {
    _ = @import("tests/semver_test.zig");
    _ = @import("tests/lockfile_test.zig");
    _ = @import("tests/resolver_test.zig");
    _ = @import("tests/hoister_test.zig");
}
