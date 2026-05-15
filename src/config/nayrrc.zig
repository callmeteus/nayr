//! .nayrrc Parser
//!
//! Parses `.nayrrc` files (TOML-like format, exclusive to nayr).
//! This file controls nayr-specific behaviour that has no equivalent in
//! `.npmrc` or `.yarnrc`.
//!
//! Supported sections:
//!
//!   [registry.<name>]    - private registry configuration
//!   [git]                - git dependency hash pinning behaviour
//!   [security]           - supply-chain security policies
//!
//! Example:
//!
//! ```toml
//! [registry.private]
//! url = "http://npm.arpa"
//! type = "verdaccio"
//! auto-sync = true
//!
//! [git]
//! pin-hash = true
//! no-pin-orgs = ["example"]
//! no-pin-repos = ["example/package"]
//!
//! [security]
//! # Minimum age (in seconds or human string) a package version must have
//! # before nayr resolves it.  "0" disables the check.
//! minimum-package-age = "24h"
//! # Registries allowed to serve packages (glob patterns, scheme optional).
//! allowed-registries = ["registry.npmjs.org", "npm.arpa*"]
//! # Git hosts / URL prefixes allowed as git dependencies.
//! allowed-git-hosts = ["github.com/even7hq/*", "github.com/callmeteus/*"]
//! ```

const std = @import("std");
const types = @import("types.zig");
const Config = types.Config;
const RegistryConfig = types.RegistryConfig;

// ============================================================================
// Public API
// ============================================================================

/// Parses a `.nayrrc` file and merges its values into `config`.
///
/// ## Parameters
/// - `config`: The config to merge into.
/// - `path`: Absolute path to the `.nayrrc` file.
/// - `overwrite`: When true, values from this file overwrite existing ones.
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

/// Parses a `.nayrrc` byte slice and merges into `config`.
pub fn parseSlice(config: *Config, src: []const u8, overwrite: bool) !void {
    var parser = NayrrcParser{
        .src = src,
        .pos = 0,
        .allocator = config.allocator,
    };
    try parser.parse(config, overwrite);
}

// ============================================================================
// Parser
// ============================================================================

const NayrrcParser = struct {
    src: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    /// Current section being parsed (e.g. "registry.private", "git").
    current_section: []const u8 = "",

    /// Registry name being built (e.g. "private" when section = "registry.private").
    current_registry_name: ?[]const u8 = null,
    current_registry: ?RegistryConfig = null,

    fn atEnd(self: *const NayrrcParser) bool {
        return self.pos >= self.src.len;
    }

    fn parse(self: *NayrrcParser, config: *Config, overwrite: bool) !void {
        while (!self.atEnd()) {
            const line = self.readLine();
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (trimmed[0] == '[') {
                // Flush previous registry section before switching.
                try self.flushRegistry(config);
                // Free the previous section name if it was heap-allocated.
                if (self.current_section.len > 0) self.allocator.free(self.current_section);
                self.current_section = try self.parseSection(trimmed);
                continue;
            }

            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..eq], " \t");
            const raw_val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");

            if (std.mem.startsWith(u8, self.current_section, "registry.")) {
                const reg_name = self.current_section["registry.".len..];
                try self.applyRegistryKey(config, reg_name, key, raw_val, overwrite);
            } else if (std.mem.eql(u8, self.current_section, "git")) {
                try applyGitKey(config, key, raw_val, overwrite, self.allocator);
            } else if (std.mem.eql(u8, self.current_section, "links")) {
                try applyLinksKey(config, key, raw_val, overwrite, self.allocator);
            } else if (std.mem.eql(u8, self.current_section, "security")) {
                try applySecurityKey(config, key, raw_val, overwrite, self.allocator);
            }
        }
        // Flush final registry section.
        try self.flushRegistry(config);
        // Free the last section name.
        if (self.current_section.len > 0) self.allocator.free(self.current_section);
        self.current_section = "";
    }

    fn readLine(self: *NayrrcParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
        const end = self.pos;
        if (self.pos < self.src.len) self.pos += 1;
        return self.src[start..end];
    }

    fn parseSection(self: *NayrrcParser, line: []const u8) ![]const u8 {
        const close = std.mem.indexOfScalar(u8, line, ']') orelse return error.MalformedSection;
        return self.allocator.dupe(u8, std.mem.trim(u8, line[1..close], " "));
    }

    fn applyRegistryKey(
        self: *NayrrcParser,
        config: *Config,
        reg_name: []const u8,
        key: []const u8,
        raw_val: []const u8,
        overwrite: bool,
    ) !void {
        // Lazily create the registry config for this section.
        if (self.current_registry == null) {
            self.current_registry = RegistryConfig{
                .name = try self.allocator.dupe(u8, reg_name),
                .url = "",
            };
        }

        const val = stripQuotes(raw_val);

        if (std.mem.eql(u8, key, "url")) {
            if (overwrite or self.current_registry.?.url.len == 0) {
                if (self.current_registry.?.url.len > 0) self.allocator.free(self.current_registry.?.url);
                self.current_registry.?.url = try self.allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, key, "type")) {
            if (std.mem.eql(u8, val, "verdaccio")) {
                self.current_registry.?.registry_type = .verdaccio;
            } else {
                self.current_registry.?.registry_type = .npm;
            }
        } else if (std.mem.eql(u8, key, "auto-sync")) {
            self.current_registry.?.auto_sync = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "auth-token-env")) {
            if (self.current_registry.?.auth_token_env) |old| self.allocator.free(old);
            self.current_registry.?.auth_token_env = try self.allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "scopes")) {
            // Parse an inline array: `scopes = ["@lemon", "@luckymaker"]`
            if (self.current_registry.?.scopes.len > 0) {
                for (self.current_registry.?.scopes) |s| self.allocator.free(s);
                self.allocator.free(self.current_registry.?.scopes);
            }
            self.current_registry.?.scopes = try parseStringArray(self.allocator, val);
        }

        _ = config;
    }

    fn flushRegistry(self: *NayrrcParser, config: *Config) !void {
        const reg = self.current_registry orelse return;
        const name = try self.allocator.dupe(u8, reg.name);
        try config.private_registries.put(self.allocator, name, reg);
        self.current_registry = null;
    }
};

// ============================================================================
// Git section handler
// ============================================================================

fn applyGitKey(
    config: *Config,
    key: []const u8,
    raw_val: []const u8,
    overwrite: bool,
    allocator: std.mem.Allocator,
) !void {
    const val = stripQuotes(raw_val);

    if (std.mem.eql(u8, key, "pin-hash")) {
        if (overwrite) config.git_pin_hash = std.mem.eql(u8, val, "true");
    } else if (std.mem.eql(u8, key, "no-pin-orgs")) {
        if (overwrite or config.git_no_pin_orgs.len == 0) {
            if (config.git_no_pin_orgs.len > 0) {
                for (config.git_no_pin_orgs) |s| allocator.free(s);
                allocator.free(config.git_no_pin_orgs);
            }
            config.git_no_pin_orgs = try parseStringArray(allocator, val);
        }
    } else if (std.mem.eql(u8, key, "no-pin-repos")) {
        if (overwrite or config.git_no_pin_repos.len == 0) {
            if (config.git_no_pin_repos.len > 0) {
                for (config.git_no_pin_repos) |s| allocator.free(s);
                allocator.free(config.git_no_pin_repos);
            }
            config.git_no_pin_repos = try parseStringArray(allocator, val);
        }
    }
}

// ============================================================================
// Links section handler
// ============================================================================

fn applyLinksKey(
    config: *Config,
    key: []const u8,
    raw_val: []const u8,
    overwrite: bool,
    allocator: std.mem.Allocator,
) !void {
    _ = overwrite;
    // Each key is a glob pattern like "@lemon/*" or "@luckymaker/*".
    // The value is expected to be "true" (the only meaningful value for now).
    // We append the pattern to config.auto_link_patterns if not already present.
    const val = stripQuotes(raw_val);
    if (!std.mem.eql(u8, val, "true")) return;

    // De-duplicate: skip if already registered.
    for (config.auto_link_patterns) |existing| {
        if (std.mem.eql(u8, existing, key)) return;
    }

    const pattern = try allocator.dupe(u8, key);
    errdefer allocator.free(pattern);

    const new_len = config.auto_link_patterns.len + 1;
    const new_slice = try allocator.alloc([]const u8, new_len);
    if (config.auto_link_patterns.len > 0) {
        @memcpy(new_slice[0..config.auto_link_patterns.len], config.auto_link_patterns);
        allocator.free(config.auto_link_patterns);
    }
    new_slice[new_len - 1] = pattern;
    config.auto_link_patterns = new_slice;
}

// ============================================================================
// Security section handler
// ============================================================================

fn applySecurityKey(
    config: *Config,
    key: []const u8,
    raw_val: []const u8,
    overwrite: bool,
    allocator: std.mem.Allocator,
) !void {
    const val = stripQuotes(raw_val);

    if (std.mem.eql(u8, key, "minimum-package-age")) {
        if (overwrite) config.minimum_package_age_seconds = parseAgeString(val);
    } else if (std.mem.eql(u8, key, "allowed-registries")) {
        if (overwrite or config.allowed_registries == null) {
            if (config.allowed_registries) |ar| {
                for (ar) |s| allocator.free(s);
                allocator.free(ar);
            }
            const arr = try parseStringArray(allocator, val);
            config.allowed_registries = if (arr.len > 0) arr else null;
        }
    } else if (std.mem.eql(u8, key, "allowed-git-hosts")) {
        if (overwrite or config.allowed_git_hosts == null) {
            if (config.allowed_git_hosts) |ag| {
                for (ag) |s| allocator.free(s);
                allocator.free(ag);
            }
            const arr = try parseStringArray(allocator, val);
            config.allowed_git_hosts = if (arr.len > 0) arr else null;
        }
    }
}

/// Parses a human-readable age string to seconds.
///
/// Supported formats:
///   `"0"`    → 0 (disabled)
///   `"30m"`  → 1800
///   `"24h"`  → 86400
///   `"1d"`   → 86400
///   `"7d"`   → 604800
///   `"3600"` → 3600 (bare number treated as seconds)
fn parseAgeString(s: []const u8) u64 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return 0;
    if (t[t.len - 1] == 'h') {
        const n = std.fmt.parseInt(u64, t[0 .. t.len - 1], 10) catch return 0;
        return n * 3600;
    } else if (t[t.len - 1] == 'd') {
        const n = std.fmt.parseInt(u64, t[0 .. t.len - 1], 10) catch return 0;
        return n * 86400;
    } else if (t[t.len - 1] == 'm') {
        const n = std.fmt.parseInt(u64, t[0 .. t.len - 1], 10) catch return 0;
        return n * 60;
    }
    return std.fmt.parseInt(u64, t, 10) catch 0;
}

// ============================================================================
// Helpers
// ============================================================================

/// Parses an inline TOML-style string array: `["a", "b", "c"]`.
fn parseStringArray(allocator: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[') return &.{};

    var list = std.ArrayList([]const u8).init(allocator);
    var i: usize = 1;
    while (i < trimmed.len) {
        // Skip whitespace and commas.
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == ',' or trimmed[i] == '\t')) i += 1;
        if (i >= trimmed.len or trimmed[i] == ']') break;

        // Read a quoted string.
        if (trimmed[i] == '"') {
            i += 1;
            const start = i;
            while (i < trimmed.len and trimmed[i] != '"') i += 1;
            const item = trimmed[start..i];
            try list.append(try allocator.dupe(u8, item));
            if (i < trimmed.len) i += 1; // skip closing "
        } else {
            // Bare word (no quotes).
            const start = i;
            while (i < trimmed.len and trimmed[i] != ',' and trimmed[i] != ']') i += 1;
            const item = std.mem.trim(u8, trimmed[start..i], " \t");
            if (item.len > 0) try list.append(try allocator.dupe(u8, item));
        }
    }
    return list.toOwnedSlice();
}

/// Strips surrounding double-quotes from a value.
fn stripQuotes(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    return t;
}
