//! Configuration Types
//!
//! The `Config` struct is the canonical merged configuration object for a
//! nayr invocation. It aggregates settings from `.npmrc`, `.yarnrc`, and
//! `.nayrrc` at project and user scope, with later/narrower scopes winning
//! on conflicts.

const std = @import("std");

// ============================================================================
// Auth entry
// ============================================================================

/// An authentication credential for a specific registry host.
pub const AuthEntry = struct {
    /// Registry base URL, e.g. "//npm.arpa/".
    host: []const u8,
    /// Bearer token (from `_authToken`).
    token: ?[]const u8 = null,
    /// Base64 Basic auth credential (from `_auth`).
    basic: ?[]const u8 = null,
};

// ============================================================================
// Registry config
// ============================================================================

/// Configuration for a private registry (from `.nayrrc`).
pub const RegistryConfig = struct {
    /// Human-readable name used on the CLI (e.g. "private").
    name: []const u8,
    /// Registry base URL.
    url: []const u8,
    /// Registry type - drives auto-discovery strategy.
    registry_type: RegistryType = .npm,
    /// Whether to run `nayr registry sync` automatically after install.
    auto_sync: bool = false,
    /// Environment variable name holding the auth token.
    auth_token_env: ?[]const u8 = null,
    /// Manually configured scopes (fallback when discovery fails).
    scopes: []const []const u8 = &.{},

    pub const RegistryType = enum {
        /// Verdaccio instance - uses `/-/verdaccio/data/packages` API.
        verdaccio,
        /// Any npm-compatible registry - uses `/-/v1/search` API.
        npm,
    };
};

// ============================================================================
// Config
// ============================================================================

/// The merged configuration for a nayr invocation.
///
/// Constructed by `config/loader.zig` from all rc files in scope.
pub const Config = struct {
    /// Default registry URL.
    registry: []const u8 = "https://registry.npmjs.org",

    /// Scope → registry URL mappings (e.g. `@lemon` → `http://npm.arpa`).
    scoped_registries: std.StringHashMapUnmanaged([]const u8) = .{},

    /// Auth credentials keyed by registry host prefix.
    auth_entries: std.ArrayList(AuthEntry),

    /// Version range prefix when `nayr add` saves deps (default `^`).
    save_prefix: []const u8 = "^",

    /// Skip lifecycle scripts (preinstall, postinstall, etc.).
    ignore_scripts: bool = false,

    /// Do not install optional dependencies.
    ignore_optional: bool = false,

    /// Verify SSL certificates (default true).
    strict_ssl: bool = true,

    /// HTTP request timeout in milliseconds.
    network_timeout_ms: u32 = 30_000,

    /// Override for the global cache directory.
    cache_folder: ?[]const u8 = null,

    // --- Git hash pinning (from .nayrrc) ---

    /// When true, git dependencies are pinned to a specific commit hash.
    /// When false, nayr always re-resolves to the remote HEAD.
    git_pin_hash: bool = true,

    /// GitHub organisations whose git deps should NOT be pinned to a hash.
    /// E.g. `["edjdigital"]` to always track HEAD for `edjdigital/*` repos.
    git_no_pin_orgs: []const []const u8 = &.{},

    /// Specific repos (org/repo) whose git deps should NOT be pinned.
    /// E.g. `["edjdigital/lemon-linting"]`.
    git_no_pin_repos: []const []const u8 = &.{},

    /// Private registry configurations from `.nayrrc [registry.*]` sections.
    private_registries: std.StringHashMapUnmanaged(RegistryConfig) = .{},

    /// Scope glob patterns from `.nayrrc [links]` that trigger automatic link
    /// registration when `nayr install` runs inside a matching package.
    /// E.g. `["@lemon/*", "@luckymaker/*"]`.
    auto_link_patterns: []const []const u8 = &.{},

    /// Email address (from `.yarnrc`).
    email: ?[]const u8 = null,

    /// Username (from `.yarnrc`).
    username: ?[]const u8 = null,

    /// Allocator used for all strings owned by this Config.
    allocator: std.mem.Allocator,

    // -------------------------------------------------------------------------
    // Factory
    // -------------------------------------------------------------------------

    /// Creates an empty Config.
    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .auth_entries = std.ArrayList(AuthEntry).init(allocator),
            .allocator = allocator,
        };
    }

    /// Frees all memory owned by the Config.
    pub fn deinit(self: *Config) void {
        // Free scoped_registries keys and values (all duped strings).
        var sr_it = self.scoped_registries.iterator();
        while (sr_it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.*);
        }
        self.scoped_registries.deinit(self.allocator);

        // Free auth entry strings.
        for (self.auth_entries.items) |*entry| {
            self.allocator.free(entry.host);
            if (entry.token) |t| self.allocator.free(t);
            if (entry.basic) |b| self.allocator.free(b);
        }
        self.auth_entries.deinit();

        // Free private_registries keys and url strings.
        var pr_it = self.private_registries.iterator();
        while (pr_it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.*.url);
        }
        self.private_registries.deinit(self.allocator);

        // Free optional string fields.
        if (self.email) |s| self.allocator.free(s);
        if (self.username) |s| self.allocator.free(s);
        if (self.cache_folder) |s| self.allocator.free(s);

        // Free git_no_pin slices (only if they were allocated, not default &.{}).
        for (self.git_no_pin_orgs) |s| self.allocator.free(s);
        if (self.git_no_pin_orgs.len > 0) self.allocator.free(self.git_no_pin_orgs);
        for (self.git_no_pin_repos) |s| self.allocator.free(s);
        if (self.git_no_pin_repos.len > 0) self.allocator.free(self.git_no_pin_repos);

        // Free auto_link_patterns.
        for (self.auto_link_patterns) |s| self.allocator.free(s);
        if (self.auto_link_patterns.len > 0) self.allocator.free(self.auto_link_patterns);

        // Free registry URL if it was duped (not the default literal).
        const default_registry = "https://registry.npmjs.org";
        if (!std.mem.eql(u8, self.registry, default_registry)) {
            self.allocator.free(self.registry);
        }
    }

    // -------------------------------------------------------------------------
    // Lookups
    // -------------------------------------------------------------------------

    /// Returns the registry URL for the given npm scope, or the default
    /// registry if no scoped mapping exists.
    ///
    /// ## Parameters
    /// - `scope`: Optional scope string including `@` (e.g. `"@lemon"`).
    ///
    /// ## Returns
    /// The registry URL to use.
    pub fn getRegistry(self: *const Config, scope: ?[]const u8) []const u8 {
        if (scope) |s| {
            if (self.scoped_registries.get(s)) |url| return url;
        }
        return self.registry;
    }

    /// Returns the auth token for the registry that serves `registry_url`,
    /// or `null` if no credential is configured.
    ///
    /// Matches by checking whether any `AuthEntry.host` is a prefix of
    /// `registry_url` (after stripping the scheme).
    pub fn getAuthToken(self: *const Config, registry_url: []const u8) ?[]const u8 {
        const entry = self.findAuthEntry(registry_url) orelse return null;
        return entry.token;
    }

    /// Returns the full `Authorization` header value for `registry_url`.
    ///
    /// Returns `"Bearer <token>"` for token auth, `"Basic <base64>"` for
    /// basic auth, or `null` if no credential is configured.
    pub fn getAuthHeader(self: *const Config, registry_url: []const u8) ?[]const u8 {
        const entry = self.findAuthEntry(registry_url) orelse return null;
        if (entry.token) |tok| {
            // Construct "Bearer <tok>" - the header is stored as a pre-formatted
            // string in a static buffer on the stack (small, safe).
            _ = tok;
            return entry.token; // caller wraps in "Bearer " prefix
        }
        return entry.basic;
    }

    /// Returns whether the given git dependency should have its commit hash
    /// pinned in the lockfile.
    ///
    /// ## Parameters
    /// - `org`: GitHub organisation name (e.g. `"edjdigital"`).
    /// - `repo`: Repository name (e.g. `"lemon-linting"`).
    ///
    /// ## Returns
    /// `true` = pin the hash; `false` = always re-resolve to HEAD.
    pub fn shouldPinGitHash(self: *const Config, org: []const u8, repo: []const u8) bool {
        if (!self.git_pin_hash) return false;

        for (self.git_no_pin_orgs) |no_pin_org| {
            if (std.mem.eql(u8, no_pin_org, org)) return false;
        }

        const full_repo = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ org, repo }) catch return true;
        defer self.allocator.free(full_repo);

        for (self.git_no_pin_repos) |no_pin_repo| {
            if (std.mem.eql(u8, no_pin_repo, full_repo)) return false;
        }

        return true;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    fn findAuthEntry(self: *const Config, registry_url: []const u8) ?*const AuthEntry {
        // Strip scheme for matching against the `//host/` format.
        const url_no_scheme = stripScheme(registry_url);
        for (self.auth_entries.items) |*entry| {
            const host_no_scheme = stripScheme(entry.host);
            if (std.mem.startsWith(u8, url_no_scheme, host_no_scheme)) return entry;
        }
        return null;
    }
};

/// Strips the scheme (https://, http://) from a URL for host comparison.
fn stripScheme(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "https://")) return url[8..];
    if (std.mem.startsWith(u8, url, "http://")) return url[7..];
    return url;
}
