//! .npmrc Parser
//!
//! Parses `.npmrc` files (INI-like key=value format) and extracts:
//!   - Default registry
//!   - Scoped registries:     `@scope:registry=URL`
//!   - Bearer auth tokens:    `//host/:_authToken=TOKEN`
//!   - Basic auth:            `//host/:_auth=BASE64`
//!   - Username/password:     `//host/:username`, `//host/:_password`
//!   - Environment variable expansion: `${VAR_NAME}`

const std = @import("std");
const types = @import("types.zig");
const Config = types.Config;
const AuthEntry = types.AuthEntry;

// ============================================================================
// Public API
// ============================================================================

/// Parses a `.npmrc` file and merges its values into `config`.
///
/// Unknown keys are silently ignored. This function may be called multiple
/// times (for project, user, and global `.npmrc` files); later calls do NOT
/// overwrite values that were already set unless the value is empty.
///
/// ## Parameters
/// - `config`: The config to merge into.
/// - `path`: Absolute path to the `.npmrc` file.
/// - `overwrite`: When true, values from this file overwrite existing ones.
pub fn parseFile(config: *Config, path: []const u8, overwrite: bool) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();
    const contents = try file.readToEndAlloc(config.allocator, 256 * 1024);
    defer config.allocator.free(contents);
    try parseSlice(config, contents, overwrite);
}

/// Parses an `.npmrc` byte slice and merges into `config`.
pub fn parseSlice(config: *Config, src: []const u8, overwrite: bool) !void {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const raw_key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        const val = try expandEnvVars(config.allocator, raw_val);
        defer config.allocator.free(val);

        try applyKey(config, raw_key, val, overwrite);
    }
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Applies a single key=value pair to the config.
fn applyKey(config: *Config, key: []const u8, val: []const u8, overwrite: bool) !void {
    // Default registry.
    if (std.mem.eql(u8, key, "registry")) {
        if (overwrite or std.mem.eql(u8, config.registry, "https://registry.npmjs.org")) {
            const default_registry = "https://registry.npmjs.org";
            if (!std.mem.eql(u8, config.registry, default_registry)) {
                config.allocator.free(config.registry);
            }
            config.registry = try config.allocator.dupe(u8, val);
        }
        return;
    }

    // Scoped registry: `@scope:registry=URL`
    if (std.mem.endsWith(u8, key, ":registry")) {
        const scope = key[0 .. key.len - ":registry".len];
        if (overwrite or !config.scoped_registries.contains(scope)) {
            // Free old key+value before overwriting so we don't leak when the
            // same file is parsed twice (e.g. ~/.npmrc as both user and project).
            if (config.scoped_registries.fetchRemove(scope)) |old| {
                config.allocator.free(old.key);
                config.allocator.free(old.value);
            }
            const scope_dup = try config.allocator.dupe(u8, scope);
            const val_dup = try config.allocator.dupe(u8, val);
            try config.scoped_registries.put(config.allocator, scope_dup, val_dup);
        }
        return;
    }

    // Auth token: `//host/:_authToken=TOKEN`
    if (std.mem.endsWith(u8, key, ":_authToken")) {
        const host = key[0 .. key.len - ":_authToken".len];
        try upsertAuthToken(config, host, val, overwrite);
        return;
    }

    // Basic auth: `//host/:_auth=BASE64`
    if (std.mem.endsWith(u8, key, ":_auth")) {
        const host = key[0 .. key.len - ":_auth".len];
        try upsertAuthBasic(config, host, val, overwrite);
        return;
    }

    // Misc settings.
    if (std.mem.eql(u8, key, "strict-ssl")) {
        if (overwrite) config.strict_ssl = std.mem.eql(u8, val, "true");
    }

    if (std.mem.eql(u8, key, "network-timeout")) {
        if (overwrite) {
            config.network_timeout_ms = std.fmt.parseInt(u32, val, 10) catch config.network_timeout_ms;
        }
    }

    if (std.mem.eql(u8, key, "cache")) {
        if (overwrite or config.cache_folder == null) {
            config.cache_folder = try config.allocator.dupe(u8, val);
        }
    }
}

/// Inserts or updates the auth token for a given registry host.
fn upsertAuthToken(config: *Config, host: []const u8, token: []const u8, overwrite: bool) !void {
    for (config.auth_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.host, host)) {
            if (overwrite or entry.token == null) {
                entry.token = try config.allocator.dupe(u8, token);
            }
            return;
        }
    }
    try config.auth_entries.append(.{
        .host = try config.allocator.dupe(u8, host),
        .token = try config.allocator.dupe(u8, token),
    });
}

/// Inserts or updates the basic auth for a given registry host.
fn upsertAuthBasic(config: *Config, host: []const u8, basic: []const u8, overwrite: bool) !void {
    for (config.auth_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.host, host)) {
            if (overwrite or entry.basic == null) {
                entry.basic = try config.allocator.dupe(u8, basic);
            }
            return;
        }
    }
    try config.auth_entries.append(.{
        .host = try config.allocator.dupe(u8, host),
        .basic = try config.allocator.dupe(u8, basic),
    });
}

/// Expands `${VAR}` references in `s` using the current environment.
///
/// Returns a newly allocated string (caller must free).
fn expandEnvVars(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "${") == null) {
        return allocator.dupe(u8, s);
    }

    var out = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '$' and s[i + 1] == '{') {
            const close = std.mem.indexOfScalarPos(u8, s, i + 2, '}') orelse {
                try out.append(s[i]);
                i += 1;
                continue;
            };
            const var_name = s[i + 2 .. close];
            const var_val = std.process.getEnvVarOwned(allocator, var_name) catch "";
            defer if (var_val.len > 0) allocator.free(var_val);
            try out.appendSlice(var_val);
            i = close + 1;
        } else {
            try out.append(s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}
