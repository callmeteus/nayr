//! .yarnrc Parser
//!
//! Parses `.yarnrc` files (Yarn Classic key-space-value format).
//! Relevant keys extracted:
//!   - registry
//!   - save-prefix
//!   - ignore-scripts
//!   - ignore-optional
//!   - strict-ssl
//!   - network-timeout
//!   - cache-folder
//!   - email
//!   - username

const std = @import("std");
const types = @import("types.zig");
const Config = types.Config;

// ============================================================================
// Public API
// ============================================================================

/// Parses a `.yarnrc` file and merges its values into `config`.
///
/// Values from this file overwrite `.npmrc` values when both define the same
/// setting (Yarn Classic behaviour).
///
/// ## Parameters
/// - `config`: The config to merge into.
/// - `path`: Absolute path to the `.yarnrc` file.
/// - `overwrite`: Whether to overwrite already-set values.
pub fn parseFile(config: *Config, path: []const u8, overwrite: bool) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();
    const contents = try file.readToEndAlloc(config.allocator, 64 * 1024);
    defer config.allocator.free(contents);
    try parseSlice(config, contents, overwrite);
}

/// Parses a `.yarnrc` byte slice and merges into `config`.
pub fn parseSlice(config: *Config, src: []const u8, overwrite: bool) !void {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Key and value are separated by the first whitespace run.
        const sep = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const key = line[0..sep];
        const raw_val = std.mem.trim(u8, line[sep + 1 ..], " \t");

        // Strip optional surrounding quotes from the value.
        const val = stripQuotes(raw_val);

        try applyKey(config, key, val, overwrite);
    }
}

// ============================================================================
// Internal helpers
// ============================================================================

fn applyKey(config: *Config, key: []const u8, val: []const u8, overwrite: bool) !void {
    if (std.mem.eql(u8, key, "registry")) {
        if (overwrite) config.registry = try config.allocator.dupe(u8, val);
    } else if (std.mem.eql(u8, key, "save-prefix")) {
        if (overwrite) config.save_prefix = try config.allocator.dupe(u8, val);
    } else if (std.mem.eql(u8, key, "ignore-scripts")) {
        if (overwrite) config.ignore_scripts = std.mem.eql(u8, val, "true");
    } else if (std.mem.eql(u8, key, "ignore-optional")) {
        if (overwrite) config.ignore_optional = std.mem.eql(u8, val, "true");
    } else if (std.mem.eql(u8, key, "strict-ssl")) {
        if (overwrite) config.strict_ssl = std.mem.eql(u8, val, "true");
    } else if (std.mem.eql(u8, key, "network-timeout")) {
        if (overwrite) {
            config.network_timeout_ms = std.fmt.parseInt(u32, val, 10) catch config.network_timeout_ms;
        }
    } else if (std.mem.eql(u8, key, "cache-folder")) {
        if (overwrite or config.cache_folder == null) {
            if (overwrite) if (config.cache_folder) |s| config.allocator.free(s);
            config.cache_folder = try config.allocator.dupe(u8, val);
        }
    } else if (std.mem.eql(u8, key, "email")) {
        if (overwrite or config.email == null) {
            if (overwrite) if (config.email) |s| config.allocator.free(s);
            config.email = try config.allocator.dupe(u8, val);
        }
    } else if (std.mem.eql(u8, key, "username")) {
        if (overwrite or config.username == null) {
            if (overwrite) if (config.username) |s| config.allocator.free(s);
            config.username = try config.allocator.dupe(u8, val);
        }
    }
}

/// Strips surrounding double-quotes from a string value.
fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}
