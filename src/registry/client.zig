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
const IoTrace = @import("../util/io_trace.zig").IoTrace;
const Config = config_types.Config;
const PackageMetadata = reg_types.PackageMetadata;
const VersionInfo = reg_types.VersionInfo;

// ============================================================================
// Registry error message propagation
// ============================================================================

/// Holds the last registry-returned error string (e.g. "no such package
/// available") so the caller can emit it through the proper output channel
/// instead of printing to stderr directly (which would corrupt the TUI).
var last_registry_error_buf: [512]u8 = undefined;
var last_registry_error_len: usize = 0;

fn setLastRegistryError(msg: []const u8) void {
    const n = @min(msg.len, last_registry_error_buf.len);
    @memcpy(last_registry_error_buf[0..n], msg[0..n]);
    last_registry_error_len = n;
}

/// Returns the last registry error message, or an empty slice if none.
/// Does NOT clear the buffer - takeLastRegistryError clears it.
pub fn peekLastRegistryError() []const u8 {
    return last_registry_error_buf[0..last_registry_error_len];
}

/// Returns the last registry error message and clears the buffer, or an empty slice if none.
pub fn takeLastRegistryError() []const u8 {
    const s = last_registry_error_buf[0..last_registry_error_len];
    last_registry_error_len = 0;
    return s;
}

// ============================================================================
// Batch fetch API
// ============================================================================

/// A single item in a batch metadata request.
pub const BatchItem = struct {
    name: []const u8,
    optional: bool,
};

/// Result for one item in a batch metadata request.
pub const BatchResult = struct {
    /// Index into the original `[]BatchItem` slice.
    idx: usize,
    /// Parsed metadata; null on error.
    meta: ?PackageMetadata,
    /// Non-null when the fetch or parse failed.
    err: ?anyerror,
    /// Human-readable description of the failure (e.g. "Not found (url: ...)").
    /// Owned by the allocator passed to fetchMetadataBatch; caller must free.
    /// Null when err is null or no detailed message is available.
    err_msg: ?[]const u8 = null,
};

/// Fetches registry metadata for multiple packages in a single curl invocation.
///
/// Uses `curl --parallel` with HTTP/2 multiplexing (where available) so that
/// all requests share one TLS connection to the registry instead of opening a
/// new connection per package. This is dramatically faster than spawning one
/// curl process per package.
///
/// Results are written to temp files and parsed after curl exits. The order of
/// `results` matches the order of `items`.
///
/// ## Parameters
/// - `allocator`: Used for all allocations.
/// - `items`:     Slice of packages to fetch.
/// - `config`:    Registry/auth configuration.
///
/// ## Returns
/// Owned slice of `BatchResult`; caller must free and deinit each entry.
pub fn fetchMetadataBatch(
    allocator: std.mem.Allocator,
    items: []const BatchItem,
    config: *const Config,
) ![]BatchResult {
    if (items.len == 0) return allocator.alloc(BatchResult, 0);

    // Create temp file paths.  Use nanosecond timestamp + index for uniqueness.
    const batch_id: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));

    const temp_paths = try allocator.alloc([]const u8, items.len);
    defer allocator.free(temp_paths);
    var created: usize = 0;
    defer {
        for (temp_paths[0..created]) |p| {
            std.fs.deleteFileAbsolute(p) catch {};
            allocator.free(p);
        }
    }
    for (0..items.len) |i| {
        temp_paths[i] = try std.fmt.allocPrint(
            allocator,
            "/tmp/nayr-{x}-{d}.json",
            .{ batch_id, i },
        );
        created = i + 1;
    }

    // Build curl argv.  Heap strings (URLs, auth headers) go into `owned` so
    // we can free them after the child process has been spawned and waited.
    var owned = std.ArrayList([]const u8).init(allocator);
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit();
    }
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    // Set --parallel-max to the batch size so curl doesn't open MORE
    // connections than there are requests (avoids wasted sockets).
    const parallel_max_str = try std.fmt.allocPrint(allocator, "{d}", .{items.len});
    defer allocator.free(parallel_max_str);

    try argv.appendSlice(&.{
        "curl",
        "-Z", // parallel transfers
        "--parallel-max",
        parallel_max_str,
        "--http2", // HTTP/2 multiplexing; falls back to HTTP/1.1
        "--silent",
        "--show-error",
        "-L",
        "--max-time",
        "120",
        "--retry",
        "2",
        "--retry-delay",
        "1",
        "--compressed",
        "-A",
        "nayr/2.0.0",
        "-H",
        "Accept: application/vnd.npm.install-v1+json",
    });

    // Determine the primary auth token from the first item's scope.
    // This covers the common single-registry setup.  When packages span
    // multiple registries the auth header is still correct for the majority
    // of requests (npm public registry) and wrong only for private scopes -
    // acceptable for now; per-URL auth is a future improvement.
    if (items.len > 0) {
        const first_scope = extractScope(items[0].name);
        const first_reg = config.getRegistry(first_scope);
        if (config.getAuthToken(first_reg)) |tok| {
            const hdr = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{tok});
            try owned.append(hdr);
            try argv.appendSlice(&.{ "-H", hdr });
        }
    }

    // Append per-URL pairs: `<url> -o <temp_path>`.
    for (items, temp_paths) |item, temp_path| {
        const scope = extractScope(item.name);
        const registry = config.getRegistry(scope);
        const encoded = try encodeName(allocator, item.name);
        defer allocator.free(encoded);

        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ std.mem.trimRight(u8, registry, "/"), encoded },
        );
        try owned.append(url);

        try argv.append(url);
        try argv.appendSlice(&.{ "-o", temp_path });
    }

    // Spawn curl and wait for completion.  We ignore the exit code here
    // because individual URL failures (404, 403) show up as missing/invalid
    // temp files, handled per-item below.
    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |err| {
        if (err == error.FileNotFound) IoTrace.recordMissingPath("curl (not found in PATH - install curl)");
        return err;
    };
    const stderr_data = try child.stderr.?.reader().readAllAlloc(allocator, 64 * 1024);
    defer allocator.free(stderr_data);
    _ = try child.wait();

    // Parse each temp file into a result.
    const results = try allocator.alloc(BatchResult, items.len);
    for (items, temp_paths, results, 0..) |item, temp_path, *r, i| {
        r.* = BatchResult{ .idx = i, .meta = null, .err = null };

        // Record the URL we tried before parsing so that if parseMetadata
        // returns error.RegistryError the caller can show "Not found at <url>".
        const scope = extractScope(item.name);
        const registry_url = config.getRegistry(scope);
        const encoded_for_err = encodeName(allocator, item.name) catch item.name;
        defer if (encoded_for_err.ptr != item.name.ptr) allocator.free(encoded_for_err);
        const full_url = std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ std.mem.trimRight(u8, registry_url, "/"), encoded_for_err },
        ) catch null;
        defer if (full_url) |u| allocator.free(u);

        const body = blk: {
            const f = std.fs.openFileAbsolute(temp_path, .{}) catch |err| {
                r.err = err;
                continue;
            };
            defer f.close();
            break :blk f.readToEndAlloc(allocator, 128 * 1024 * 1024) catch |err| {
                r.err = err;
                continue;
            };
        };
        defer allocator.free(body);

        r.meta = parseMetadata(allocator, body) catch |err| {
            // Store per-result error message to avoid cross-contamination when
            // multiple items in the same batch fail: the global last_registry_error_buf
            // would be overwritten by each failing item, causing earlier items to
            // see later items' error messages when the resolver reads them sequentially.
            if (err == error.RegistryError) {
                const prev = peekLastRegistryError();
                if (full_url) |u| {
                    r.err_msg = std.fmt.allocPrint(
                        allocator,
                        "{s} (url: {s})",
                        .{ if (prev.len > 0) prev else "Not found", u },
                    ) catch null;
                } else if (prev.len > 0) {
                    r.err_msg = allocator.dupe(u8, prev) catch null;
                }
            }
            r.err = err;
            continue;
        };
    }

    return results;
}

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
    try argv.append(url); // URL last

    // For file downloads we don't need to capture stdout (curl writes directly
    // to the file), but we still need to drain stderr and get the exit code.
    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |err| {
        if (err == error.FileNotFound) IoTrace.recordMissingPath("curl (not found in PATH - install curl)");
        return err;
    };

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
    try argv.append("--fail"); // exit 22 on HTTP 4xx/5xx
    try argv.append("-L"); // follow redirects
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
    child.spawn() catch |err| {
        if (err == error.FileNotFound and argv.len > 0) IoTrace.recordMissingPath(argv[0]);
        return err;
    };

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

    // npm error responses look like {"error":"Not found"} — propagate the
    // message via the RegistryErrorMsg sentinel so the resolver can surface
    // it through the proper output channel (which clears the progress bar).
    if (root.object.get("error")) |err_val| {
        if (err_val == .string) {
            // Store in a thread-local so the resolver can retrieve it.
            setLastRegistryError(err_val.string);
        }
        return error.RegistryError;
    }

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

    // Back-fill published_at from the `time` map (npm registry includes this
    // in both full and abbreviated packuments).
    if (root.object.get("time")) |time_val| {
        if (time_val == .object) {
            var it = time_val.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* != .string) continue;
                const ts = parseIso8601(kv.value_ptr.*.string);
                if (ts == 0) continue;
                if (meta.versions.getPtr(kv.key_ptr.*)) |vi| {
                    vi.published_at = ts;
                }
            }
        }
    }

    return meta;
}

/// Parses an ISO 8601 UTC timestamp string to a Unix timestamp (seconds).
///
/// Accepts the format returned by the npm registry:
///   `"2023-03-16T19:22:12.000Z"`
///   `"2014-09-11T00:00:00.000Z"`
///
/// Returns 0 on any parse failure.
fn parseIso8601(s: []const u8) i64 {
    if (s.len < 19) return 0;
    const year = std.fmt.parseInt(u32, s[0..4], 10) catch return 0;
    if (s[4] != '-') return 0;
    const month = std.fmt.parseInt(u32, s[5..7], 10) catch return 0;
    if (s[7] != '-') return 0;
    const day = std.fmt.parseInt(u32, s[8..10], 10) catch return 0;
    if (s[10] != 'T') return 0;
    const hour = std.fmt.parseInt(u32, s[11..13], 10) catch return 0;
    if (s[13] != ':') return 0;
    const min = std.fmt.parseInt(u32, s[14..16], 10) catch return 0;
    if (s[16] != ':') return 0;
    const sec = std.fmt.parseInt(u32, s[17..19], 10) catch return 0;

    // Julian Day Number formula (proleptic Gregorian calendar).
    const a: i64 = @intCast((14 - month) / 12);
    const y: i64 = @as(i64, @intCast(year)) + 4800 - a;
    const m: i64 = @as(i64, @intCast(month)) + 12 * a - 3;
    const jdn: i64 = @as(i64, @intCast(day)) +
        @divFloor(153 * m + 2, 5) +
        365 * y +
        @divFloor(y, 4) -
        @divFloor(y, 100) +
        @divFloor(y, 400) -
        32045;

    // Unix epoch starts at JDN 2440588 (1970-01-01).
    const days_since_epoch = jdn - 2440588;
    const time_of_day: i64 = @as(i64, @intCast(hour)) * 3600 +
        @as(i64, @intCast(min)) * 60 +
        @as(i64, @intCast(sec));
    return days_since_epoch * 86400 + time_of_day;
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
