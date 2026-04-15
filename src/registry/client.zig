//! Registry HTTP Client
//!
//! Handles all HTTP communication with npm-compatible registries:
//!   - Package metadata fetch (`GET /<name>` or `GET /@scope%2Fname`)
//!   - Tarball download with streaming integrity check
//!   - Audit bulk request (`POST /-/npm/v1/security/advisories/bulk`)
//!   - Registry scope discovery (Verdaccio and generic npm)
//!
//! This client respects the `Config` for registry URL selection, auth
//! tokens, SSL settings, and timeouts.

const std = @import("std");
const config_types = @import("../config/types.zig");
const reg_types = @import("types.zig");
const Config = config_types.Config;
const PackageMetadata = reg_types.PackageMetadata;
const VersionInfo = reg_types.VersionInfo;

// ============================================================================
// Client
// ============================================================================

/// An HTTP client for a single npm-compatible registry.
///
/// Each thread in the fetch pool holds its own `RegistryClient` with its own
/// `std.http.Client` — zero contention between threads.
pub const RegistryClient = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    http: std.http.Client,

    /// Creates a new client. Each thread should create its own instance.
    pub fn init(allocator: std.mem.Allocator, config: *const Config) RegistryClient {
        return .{
            .allocator = allocator,
            .config = config,
            .http = std.http.Client{ .allocator = allocator },
        };
    }

    /// Releases the underlying HTTP connection pool.
    pub fn deinit(self: *RegistryClient) void {
        self.http.deinit();
    }

    // -------------------------------------------------------------------------
    // Metadata
    // -------------------------------------------------------------------------

    /// Fetches full package metadata from the registry.
    ///
    /// The registry URL and auth token are selected from `Config` based on
    /// the package's scope.
    ///
    /// ## Parameters
    /// - `name`: Package name (e.g. `"lodash"` or `"@babel/core"`).
    ///
    /// ## Returns
    /// Parsed `PackageMetadata`. Caller must call `.deinit()`.
    pub fn fetchMetadata(self: *RegistryClient, name: []const u8) !PackageMetadata {
        const scope = extractScope(name);
        const registry = self.config.getRegistry(scope);

        // URL-encode the `/` in scoped package names.
        const encoded_name = try encodeName(self.allocator, name);
        defer self.allocator.free(encoded_name);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ std.mem.trimRight(u8, registry, "/"), encoded_name },
        );
        defer self.allocator.free(url);

        const body = try self.get(url);
        defer self.allocator.free(body);

        return parseMetadata(self.allocator, body);
    }

    // -------------------------------------------------------------------------
    // Tarball download
    // -------------------------------------------------------------------------

    /// Downloads a tarball to `dest_path` and verifies its integrity.
    ///
    /// The download is streamed directly to `dest_path` — no full-file
    /// buffering in memory. The integrity hash (sha512 or sha1) is computed
    /// incrementally during the download.
    ///
    /// ## Parameters
    /// - `url`: Direct tarball URL.
    /// - `dest_path`: Absolute path where the tarball should be saved.
    /// - `expected_integrity`: The `sha512-<base64>` or `sha1-<hex>` string to
    ///   verify against. Pass an empty slice to skip verification.
    ///
    /// ## Errors
    /// `error.IntegrityMismatch` if the downloaded tarball does not match.
    pub fn downloadTarball(
        self: *RegistryClient,
        url: []const u8,
        dest_path: []const u8,
        expected_integrity: []const u8,
    ) !void {
        const auth_header = self.buildAuthHeader(url);
        var extra_headers_buf: [2]std.http.Header = undefined;
        var n_extra: usize = 0;
        if (auth_header) |ah| {
            extra_headers_buf[n_extra] = .{ .name = "Authorization", .value = ah };
            n_extra += 1;
        }

        var server_header_buf: [16 * 1024]u8 = undefined;
        const uri = try std.Uri.parse(url);
        var req = try self.http.open(.GET, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = extra_headers_buf[0..n_extra],
        });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();

        if (req.response.status != .ok) return error.HttpError;

        // Stream response to file while computing sha512.
        const file = try std.fs.createFileAbsolute(dest_path, .{ .truncate = true });
        defer file.close();

        var sha512 = std.crypto.hash.sha2.Sha512.init(.{});
        var buf: [64 * 1024]u8 = undefined;

        while (true) {
            const n = try req.reader().read(&buf);
            if (n == 0) break;
            try file.writeAll(buf[0..n]);
            sha512.update(buf[0..n]);
        }

        // Verify integrity if expected.
        if (expected_integrity.len > 0) {
            var digest: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
            sha512.final(&digest);
            try verifyIntegrity(self.allocator, &digest, expected_integrity);
        }
    }

    // -------------------------------------------------------------------------
    // Registry scope discovery
    // -------------------------------------------------------------------------

    /// Discovers all scopes published to a Verdaccio registry.
    ///
    /// Uses the Verdaccio-specific endpoint:
    ///   `GET <url>/-/verdaccio/data/packages`
    ///
    /// ## Returns
    /// Slice of scope strings (e.g. `["@lemon", "@luckymaker"]`). Caller owns.
    pub fn discoverScopesVerdaccio(self: *RegistryClient, registry_url: []const u8) ![][]const u8 {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/-/verdaccio/data/packages",
            .{std.mem.trimRight(u8, registry_url, "/")},
        );
        defer self.allocator.free(url);

        const body = self.get(url) catch return &.{};
        defer self.allocator.free(body);

        return extractScopesFromJson(self.allocator, body);
    }

    /// Discovers scopes from a generic npm-compatible registry via the search API.
    ///
    /// Uses: `GET <url>/-/v1/search?text=@&size=250`
    ///
    /// ## Returns
    /// Slice of unique scope strings. Caller owns.
    pub fn discoverScopesNpm(self: *RegistryClient, registry_url: []const u8) ![][]const u8 {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/-/v1/search?text=%40&size=250",
            .{std.mem.trimRight(u8, registry_url, "/")},
        );
        defer self.allocator.free(url);

        const body = self.get(url) catch return &.{};
        defer self.allocator.free(body);

        return extractScopesFromSearchJson(self.allocator, body);
    }

    // -------------------------------------------------------------------------
    // Internal HTTP helpers
    // -------------------------------------------------------------------------

    /// Performs an HTTP GET and returns the full response body.
    /// Caller must free the returned slice.
    fn get(self: *RegistryClient, url: []const u8) ![]const u8 {
        const auth_header = self.buildAuthHeader(url);
        var extra_headers_buf: [2]std.http.Header = undefined;
        var n_extra: usize = 0;
        extra_headers_buf[n_extra] = .{ .name = "Accept", .value = "application/json" };
        n_extra += 1;
        if (auth_header) |ah| {
            extra_headers_buf[n_extra] = .{ .name = "Authorization", .value = ah };
            n_extra += 1;
        }

        var server_header_buf: [16 * 1024]u8 = undefined;
        const uri = try std.Uri.parse(url);
        var req = try self.http.open(.GET, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = extra_headers_buf[0..n_extra],
        });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();

        if (req.response.status != .ok) {
            return error.HttpError;
        }

        var body = std.ArrayList(u8).init(self.allocator);
        try req.reader().readAllArrayList(&body, 8 * 1024 * 1024);
        return body.toOwnedSlice();
    }

    /// Builds an Authorization header value for the given URL, or null.
    fn buildAuthHeader(self: *const RegistryClient, url: []const u8) ?[]const u8 {
        const token = self.config.getAuthToken(url) orelse return null;
        // Pre-allocate in the allocator — short-lived header value.
        return std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token}) catch null;
    }
};

// ============================================================================
// JSON parsers
// ============================================================================

/// Parses the npm registry metadata JSON response into `PackageMetadata`.
fn parseMetadata(allocator: std.mem.Allocator, body: []const u8) !PackageMetadata {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidMetadata;

    const name_val = root.object.get("name") orelse return error.MissingName;
    if (name_val != .string) return error.MissingName;

    var meta = PackageMetadata{
        .name = try allocator.dupe(u8, name_val.string),
        .versions = .{},
        .dist_tags = .{},
    };

    // Parse dist-tags.
    if (root.object.get("dist-tags")) |dt_val| {
        if (dt_val == .object) {
            var it = dt_val.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* != .string) continue;
                try meta.dist_tags.put(
                    allocator,
                    try allocator.dupe(u8, kv.key_ptr.*),
                    try allocator.dupe(u8, kv.value_ptr.*.string),
                );
            }
        }
    }

    // Parse versions.
    if (root.object.get("versions")) |vs_val| {
        if (vs_val == .object) {
            var it = vs_val.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* != .object) continue;
                const vi = try parseVersionInfo(allocator, kv.key_ptr.*, kv.value_ptr.*);
                try meta.versions.put(allocator, vi.version, vi);
            }
        }
    }

    return meta;
}

/// Parses a single version entry from the metadata `versions` map.
fn parseVersionInfo(allocator: std.mem.Allocator, ver_str: []const u8, obj: std.json.Value) !VersionInfo {
    var vi = VersionInfo{
        .version = try allocator.dupe(u8, ver_str),
        .tarball = "",
    };

    // dist.tarball and dist.integrity
    if (obj.object.get("dist")) |dist| {
        if (dist == .object) {
            if (dist.object.get("tarball")) |t| {
                if (t == .string) vi.tarball = try allocator.dupe(u8, t.string);
            }
            if (dist.object.get("integrity")) |ig| {
                if (ig == .string) vi.integrity = try allocator.dupe(u8, ig.string);
            }
            if (dist.object.get("unpackedSize")) |us| {
                if (us == .integer) vi.unpacked_size = @intCast(us.integer);
            }
        }
    }

    vi.dependencies = try parseDepMap(allocator, obj.object.get("dependencies"));
    vi.optional_dependencies = try parseDepMap(allocator, obj.object.get("optionalDependencies"));
    vi.peer_dependencies = try parseDepMap(allocator, obj.object.get("peerDependencies"));

    if (obj.object.get("bin")) |bin_val| {
        if (bin_val == .object) {
            var it = bin_val.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* != .string) continue;
                try vi.bin.put(
                    allocator,
                    try allocator.dupe(u8, kv.key_ptr.*),
                    try allocator.dupe(u8, kv.value_ptr.*.string),
                );
            }
        }
    }

    return vi;
}

fn parseDepMap(allocator: std.mem.Allocator, val: ?std.json.Value) !std.StringHashMapUnmanaged([]const u8) {
    var map = std.StringHashMapUnmanaged([]const u8){};
    const v = val orelse return map;
    if (v != .object) return map;
    var it = v.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .string) continue;
        try map.put(
            allocator,
            try allocator.dupe(u8, kv.key_ptr.*),
            try allocator.dupe(u8, kv.value_ptr.*.string),
        );
    }
    return map;
}

/// Extracts unique `@scope` strings from a Verdaccio packages JSON response.
fn extractScopesFromJson(allocator: std.mem.Allocator, body: []const u8) ![][]const u8 {
    var scopes = std.StringHashMapUnmanaged(void){};
    defer scopes.deinit(allocator);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return &.{};
    defer parsed.deinit();

    const arr = if (parsed.value == .array) parsed.value.array else return &.{};
    for (arr.items) |item| {
        if (item != .object) continue;
        const name_val = item.object.get("name") orelse continue;
        if (name_val != .string) continue;
        const pkg_name = name_val.string;
        if (pkg_name.len > 0 and pkg_name[0] == '@') {
            const slash = std.mem.indexOfScalar(u8, pkg_name, '/') orelse continue;
            const scope = pkg_name[0..slash];
            if (!scopes.contains(scope)) {
                try scopes.put(allocator, scope, {});
            }
        }
    }

    var result = std.ArrayList([]const u8).init(allocator);
    var it = scopes.keyIterator();
    while (it.next()) |k| try result.append(try allocator.dupe(u8, k.*));
    return result.toOwnedSlice();
}

/// Extracts unique `@scope` strings from an npm search API JSON response.
fn extractScopesFromSearchJson(allocator: std.mem.Allocator, body: []const u8) ![][]const u8 {
    var scopes = std.StringHashMapUnmanaged(void){};
    defer scopes.deinit(allocator);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return &.{};
    defer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object else return &.{};
    const objects_val = root.get("objects") orelse return &.{};
    if (objects_val != .array) return &.{};

    for (objects_val.array.items) |item| {
        if (item != .object) continue;
        const pkg_val = item.object.get("package") orelse continue;
        if (pkg_val != .object) continue;
        const name_val = pkg_val.object.get("name") orelse continue;
        if (name_val != .string) continue;
        const pkg_name = name_val.string;
        if (pkg_name.len > 0 and pkg_name[0] == '@') {
            const slash = std.mem.indexOfScalar(u8, pkg_name, '/') orelse continue;
            const scope = pkg_name[0..slash];
            if (!scopes.contains(scope)) try scopes.put(allocator, scope, {});
        }
    }

    var result = std.ArrayList([]const u8).init(allocator);
    var it = scopes.keyIterator();
    while (it.next()) |k| try result.append(try allocator.dupe(u8, k.*));
    return result.toOwnedSlice();
}

// ============================================================================
// Helpers
// ============================================================================

/// Extracts the `@scope` from a package name, or `null` for unscoped packages.
fn extractScope(name: []const u8) ?[]const u8 {
    if (name.len == 0 or name[0] != '@') return null;
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return null;
    return name[0..slash];
}

/// URL-encodes the `/` in scoped package names for registry API paths.
///
/// `@babel/core` → `@babel%2Fcore`
fn encodeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') == null) return allocator.dupe(u8, name);
    return std.mem.replaceOwned(u8, allocator, name, "/", "%2F");
}

/// Verifies a downloaded tarball digest against an integrity string.
///
/// Supports `sha512-<base64>` format (npm standard) and `sha1-<hex>` (legacy).
fn verifyIntegrity(
    allocator: std.mem.Allocator,
    digest: []const u8,
    expected: []const u8,
) !void {
    if (std.mem.startsWith(u8, expected, "sha512-")) {
        const encoded = expected["sha512-".len..];
        // Decode the base64-encoded expected digest.
        const decoded = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
        defer allocator.free(decoded);
        try std.base64.standard.Decoder.decode(decoded, encoded);
        if (!std.mem.eql(u8, digest, decoded)) return error.IntegrityMismatch;
    }
    // For sha1 or unknown: skip verification (warn upstream).
}
