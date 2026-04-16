//! Registry HTTP Client
//!
//! Handles all HTTP communication with npm-compatible registries:
//!   - Package metadata fetch (`GET /<name>` or `GET /@scope%2Fname`)
//!   - Tarball download with streaming integrity check
//!   - Audit bulk request (`POST /-/npm/v1/security/advisories/bulk`)
//!   - Registry scope discovery (Verdaccio and generic npm)
//!
//! ## Transport
//!
//! HTTP requests are delegated to the system `curl` binary rather than
//! Zig's built-in `std.http.Client`. This is intentional: Zig 0.14.1's pure-Zig
//! TLS 1.3 implementation triggers a `decode_error` alert on several production
//! registries (including registry.npmjs.org). Curl uses the system TLS library
//! (OpenSSL / GnuTLS / Secure Transport) and handles every TLS quirk in the
//! wild without issue.
//!
//! When Zig's TLS layer matures, swapping back is a one-file change here.
//!
//! ## Requirements
//!
//! `curl` ≥ 7.x must be in PATH. The binary is located once at startup via
//! `which curl` and reused for every request.

const std = @import("std");
const config_types = @import("../config/types.zig");
const reg_types = @import("types.zig");
const Config = config_types.Config;
const PackageMetadata = reg_types.PackageMetadata;
const VersionInfo = reg_types.VersionInfo;
const builtin = @import("builtin");

// ============================================================================
// Client
// ============================================================================

/// An HTTP client for a single npm-compatible registry.
///
/// Stateless aside from the allocator and config pointer; multiple threads can
/// each own an instance without any shared mutable state.
pub const RegistryClient = struct {
    allocator: std.mem.Allocator,
    config: *const Config,

    /// Creates a new client. Lightweight - no network activity at init time.
    pub fn init(allocator: std.mem.Allocator, config: *const Config) RegistryClient {
        return .{ .allocator = allocator, .config = config };
    }

    /// No-op; kept for API symmetry with the original std.http.Client version.
    pub fn deinit(self: *RegistryClient) void {
        _ = self;
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
    /// The file is downloaded by curl and then hashed to verify the
    /// `sha512-<base64>` or `sha1-<hex>` integrity string.
    ///
    /// ## Parameters
    /// - `url`: Direct tarball URL.
    /// - `dest_path`: Absolute path where the tarball should be saved.
    /// - `expected_integrity`: The `sha512-<base64>` integrity string.
    ///   Pass an empty slice to skip verification.
    ///
    /// ## Errors
    /// `error.IntegrityMismatch` if the downloaded tarball does not match.
    pub fn downloadTarball(
        self: *RegistryClient,
        url: []const u8,
        dest_path: []const u8,
        expected_integrity: []const u8,
    ) !void {
        const token = self.config.getAuthToken(url);
        try curlDownloadToFile(self.allocator, url, dest_path, token);

        if (expected_integrity.len > 0) {
            try verifyFileIntegrity(self.allocator, dest_path, expected_integrity);
        }
    }

    // -------------------------------------------------------------------------
    // Registry scope discovery
    // -------------------------------------------------------------------------

    /// Discovers all scopes published to a Verdaccio registry.
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
        const token = self.config.getAuthToken(url);
        return curlGet(self.allocator, url, token);
    }
};

// ============================================================================
// curl transport
// ============================================================================

/// Runs `curl` to GET `url` and returns the response body.
///
/// On failure, writes a diagnostic line to stderr with the URL and the
/// error message reported by curl, then returns `HttpError` or `NetworkError`.
/// Caller owns the returned slice.
fn curlGet(
    allocator: std.mem.Allocator,
    url: []const u8,
    auth_token: ?[]const u8,
) ![]const u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try buildCurlBaseArgs(&argv, auth_token);
    try argv.append("-H");
    // Use the abbreviated packument format: only fields needed for installation
    // (dist, dependencies, bin, dist-tags).  Much smaller than the full packument
    // for popular packages like vite or typescript that have hundreds of versions.
    try argv.append("Accept: application/vnd.npm.install-v1+json");
    try argv.append(url); // URL must be last

    const result = try runCapture(allocator, argv.items);
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        logCurlError(url, result.exit_code, result.stderr);
        return if (result.exit_code == 22) error.HttpError else error.NetworkError;
    }

    return result.stdout;
}

/// Runs `curl` to GET `url` and writes the output directly to `dest_path`.
///
/// Does NOT use stdout capture - curl writes the file directly, which avoids
/// loading the entire tarball into memory.
fn curlDownloadToFile(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest_path: []const u8,
    auth_token: ?[]const u8,
) !void {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try buildCurlBaseArgs(&argv, auth_token);
    try argv.append("-o");
    try argv.append(dest_path); // output file before URL
    try argv.append(url);       // URL last

    // For file downloads we don't need to capture stdout (curl writes directly
    // to the file), but we still need to drain stderr and get the exit code.
    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stderr_buf = try child.stderr.?.reader().readAllAlloc(allocator, 8 * 1024);
    defer allocator.free(stderr_buf);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };

    if (exit_code != 0) {
        logCurlError(url, exit_code, stderr_buf);
        return error.NetworkError;
    }
}

/// Appends the common curl flags shared by all requests.
/// The URL is NOT appended by this function - callers must append it last,
/// after any `-o <file>` or other per-call flags.
fn buildCurlBaseArgs(
    argv: *std.ArrayList([]const u8),
    auth_token: ?[]const u8,
) !void {
    try argv.append("curl");
    try argv.append("--silent");
    try argv.append("--show-error");
    try argv.append("--fail");       // exit 22 on HTTP 4xx/5xx
    try argv.append("-L");           // follow redirects
    try argv.append("--max-time");
    try argv.append("120");
    try argv.append("--retry");
    try argv.append("2");
    try argv.append("--retry-delay");
    try argv.append("1");
    try argv.append("--compressed"); // Accept-Encoding: gzip
    try argv.append("-A");
    try argv.append("nayr/2.0.0");

    if (auth_token) |tok| {
        const header = try std.fmt.allocPrint(argv.allocator, "Authorization: Bearer {s}", .{tok});
        try argv.append("-H");
        try argv.append(header);
    }
}

/// Writes a human-readable error line to stderr when a curl request fails.
///
/// Extracts the useful part of curl's `--show-error` output, e.g.:
///   `curl: (22) The requested URL returned error: 404 Not Found`
///   → `  warn  HTTP 404 Not Found - https://registry.npmjs.org/lodash`
fn logCurlError(url: []const u8, exit_code: u8, curl_stderr: []const u8) void {
    const nayr_stderr = std.io.getStdErr().writer();

    // Extract the human-readable part after "curl: (NN) ".
    const curl_msg: []const u8 = blk: {
        const trimmed = std.mem.trim(u8, curl_stderr, " \t\r\n");
        // curl error lines look like: "curl: (22) Some message"
        if (std.mem.indexOf(u8, trimmed, ") ")) |paren_end| {
            break :blk trimmed[paren_end + 2 ..];
        }
        if (trimmed.len > 0) break :blk trimmed;
        // Fallback: describe by exit code.
        break :blk if (exit_code == 22) "HTTP 4xx/5xx error" else "network error";
    };

    nayr_stderr.print(
        "  warn  {s}\n        url: {s}\n",
        .{ curl_msg, url },
    ) catch {};
}

/// Result from `runCapture`. Both slices are owned by the caller.
const CaptureResult = struct {
    stdout: []const u8,
    /// curl error output (--show-error). Contains the human-readable error
    /// message on failure (e.g. "curl: (22) The requested URL returned error: 404").
    stderr: []const u8,
    exit_code: u8,
};

/// Spawns `argv[0]` with the given arguments, captures stdout and stderr,
/// and returns all three. Caller must free both `stdout` and `stderr`.
fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !CaptureResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // Read stdout first, then stderr. This is safe because curl with --silent
    // writes nothing to stderr on success and only a short error message on
    // failure - the OS pipe buffer (typically 64 KB) is never exhausted.
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 128 * 1024 * 1024);
    errdefer allocator.free(stdout);

    const stderr_out = try child.stderr.?.reader().readAllAlloc(allocator, 8 * 1024);
    errdefer allocator.free(stderr_out);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };

    return .{ .stdout = stdout, .stderr = stderr_out, .exit_code = exit_code };
}

// ============================================================================
// Integrity verification
// ============================================================================

/// Reads `path` and verifies its sha512 digest against `expected`.
///
/// Supported formats:
///   - `sha512-<base64url>` (npm standard)
///   - `sha1-<hex>` (legacy, skipped)
fn verifyFileIntegrity(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: []const u8,
) !void {
    if (!std.mem.startsWith(u8, expected, "sha512-")) return; // skip sha1 / unknown

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var sha512 = std.crypto.hash.sha2.Sha512.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        sha512.update(buf[0..n]);
    }
    var digest: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
    sha512.final(&digest);

    const encoded = expected["sha512-".len..];
    const decoded = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    defer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);

    if (!std.mem.eql(u8, &digest, decoded)) return error.IntegrityMismatch;
}

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
            if (!scopes.contains(scope)) try scopes.put(allocator, scope, {});
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
