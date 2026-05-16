//! Configuration Loader
//!
//! Builds the merged `Config` object by reading rc files at all scopes
//! (project → user → global) and merging them in the correct priority order.
//!
//! Priority (highest wins):
//!   1. Project `.npmrc`   (cwd)
//!   2. User `.npmrc`      (~/.npmrc)
//!   3. Global `.npmrc`    (/etc/npmrc - Linux only)
//!   4. Project `.yarnrc`  - overrides `.npmrc` for Yarn-specific keys
//!   5. User `.yarnrc`     (~/.yarnrc)
//!   6. Project `.nayrrc`  - nayr-exclusive settings
//!   7. User `.nayrrc`     (~/.nayrrc)
//!
//! In practice, project-level files are the most specific. We parse from
//! least specific to most specific so that later calls can overwrite.
//! The `overwrite=true` flag is passed for higher-priority (project) files.

const std = @import("std");
const platform = @import("../util/platform.zig");
const types = @import("types.zig");
const npmrc = @import("npmrc.zig");
const yarnrc = @import("yarnrc.zig");
const nayrrc = @import("nayrrc.zig");
const Config = types.Config;

// ============================================================================
// Public API
// ============================================================================

/// Loads the merged configuration for a nayr invocation.
///
/// ## Parameters
/// - `allocator`: All config strings are allocated here.
/// - `cwd`: The current working directory (project root).
///
/// ## Returns
/// A fully populated `Config`. Caller must call `config.deinit()`.
pub fn load(allocator: std.mem.Allocator, cwd: []const u8) !Config {
    var config = Config.init(allocator);

    const home = platform.getHomeDir(allocator) catch null;
    defer if (home) |h| allocator.free(h);

    // ---------- .npmrc (least specific to most specific) ----------

    // Global (Linux only).
    try npmrc.parseFile(&config, "/etc/npmrc", false);

    // User-level ~/.npmrc.
    if (home) |h| {
        const user_npmrc = try std.fs.path.join(allocator, &.{ h, ".npmrc" });
        defer allocator.free(user_npmrc);
        try npmrc.parseFile(&config, user_npmrc, false);
    }

    // Project-level .npmrc (highest priority among npmrc files).
    const proj_npmrc = try std.fs.path.join(allocator, &.{ cwd, ".npmrc" });
    defer allocator.free(proj_npmrc);
    try npmrc.parseFile(&config, proj_npmrc, true);

    // ---------- .yarnrc (overrides npmrc for Yarn keys) ----------

    if (home) |h| {
        const user_yarnrc = try std.fs.path.join(allocator, &.{ h, ".yarnrc" });
        defer allocator.free(user_yarnrc);
        try yarnrc.parseFile(&config, user_yarnrc, false);
    }

    const proj_yarnrc = try std.fs.path.join(allocator, &.{ cwd, ".yarnrc" });
    defer allocator.free(proj_yarnrc);
    try yarnrc.parseFile(&config, proj_yarnrc, true);

    // ---------- .nayrrc (nayr-exclusive settings) ----------

    if (home) |h| {
        const user_nayrrc = try std.fs.path.join(allocator, &.{ h, ".nayrrc" });
        defer allocator.free(user_nayrrc);
        try nayrrc.parseFile(&config, user_nayrrc, false);
    }

    const proj_nayrrc = try std.fs.path.join(allocator, &.{ cwd, ".nayrrc" });
    defer allocator.free(proj_nayrrc);
    try nayrrc.parseFile(&config, proj_nayrrc, true);

    // ---------- Environment variable overrides (highest priority) ----------

    if (std.process.getEnvVarOwned(allocator, "NAYR_GIT_BUILD_DEPS")) |val| {
        defer allocator.free(val);
        if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true")) {
            config.git_build_deps = true;
        }
    } else |_| {}

    return config;
}
