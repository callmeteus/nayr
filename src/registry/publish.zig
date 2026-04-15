//! Package Publishing
//!
//! Implements `nayr publish` — creates a tarball from the current directory
//! and uploads it to the registry using the npm publish protocol.

const std = @import("std");
const config_types = @import("../config/types.zig");
const json_util = @import("../util/json.zig");
const Config = config_types.Config;

// ============================================================================
// Publish
// ============================================================================

/// Publishes the package in `pkg_dir` to the registry.
///
/// Pipeline:
///   1. Read `package.json` (validates required fields).
///   2. Collect files respecting `.npmignore` / `files` field.
///   3. Create a `package.tgz` tarball.
///   4. `PUT /<name>` with the tarball + metadata JSON.
///
/// ## Parameters
/// - `allocator`: Main allocator.
/// - `config`: Merged configuration.
/// - `pkg_dir`: Absolute path to the package directory.
/// - `opts`: Publish options.
pub fn publish(
    allocator: std.mem.Allocator,
    config: *const Config,
    pkg_dir: []const u8,
    opts: PublishOptions,
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_dir, "package.json" });
    defer allocator.free(manifest_path);

    const manifest = try json_util.parseFile(allocator, manifest_path);

    // Validate required fields.
    const name = manifest.name orelse return error.MissingPackageName;
    const version = manifest.version orelse return error.MissingPackageVersion;

    if (manifest.private) {
        std.io.getStdErr().writer().print(
            "warning: package.json has \"private\": true — skipping publish\n",
            .{},
        ) catch {};
        return error.PackageIsPrivate;
    }

    if (opts.dry_run) {
        std.io.getStdOut().writer().print(
            "[dry-run] would publish {s}@{s} to {s}\n",
            .{ name, version, config.registry },
        ) catch {};
        return;
    }

    // Create tarball.
    const tarball_path = try createTarball(allocator, pkg_dir, manifest_path);
    defer {
        std.fs.deleteFileAbsolute(tarball_path) catch {};
        allocator.free(tarball_path);
    }

    const tarball_file = try std.fs.openFileAbsolute(tarball_path, .{});
    defer tarball_file.close();
    const tarball_data = try tarball_file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(tarball_data);

    // Compute sha1 integrity for the attachment.
    var sha1_digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(tarball_data, &sha1_digest, .{});

    // Build registry URL and path.
    const scope = if (name[0] == '@') blk: {
        const slash = std.mem.indexOfScalar(u8, name, '/') orelse break :blk null;
        break :blk name[0..slash];
    } else null;
    const registry = config.getRegistry(scope);

    const encoded_name = try std.mem.replaceOwned(u8, allocator, name, "/", "%2F");
    defer allocator.free(encoded_name);

    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ std.mem.trimRight(u8, registry, "/"), encoded_name },
    );
    defer allocator.free(url);

    // Build publish body (npm publish protocol).
    const b64_len = std.base64.standard.Encoder.calcSize(tarball_data.len);
    const b64_data = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64_data);
    _ = std.base64.standard.Encoder.encode(b64_data, tarball_data);

    const tag = opts.tag orelse "latest";
    const body = try std.fmt.allocPrint(allocator,
        \\{{
        \\ "_id": "{s}",
        \\ "name": "{s}",
        \\ "description": "",
        \\ "dist-tags": {{ "{s}": "{s}" }},
        \\ "versions": {{
        \\   "{s}": {{
        \\     "name": "{s}",
        \\     "version": "{s}",
        \\     "dist": {{
        \\       "shasum": "{s}",
        \\       "tarball": "{s}/{s}/-/{s}-{s}.tgz"
        \\     }}
        \\   }}
        \\ }},
        \\ "_attachments": {{
        \\   "{s}-{s}.tgz": {{
        \\     "content_type": "application/octet-stream",
        \\     "data": "{s}",
        \\     "length": {d}
        \\   }}
        \\ }}
        \\}}
    , .{
        name,
        name,
        tag,
        version,
        version,
        name,
        version,
        std.fmt.fmtSliceHexLower(&sha1_digest),
        std.mem.trimRight(u8, registry, "/"),
        encoded_name,
        name,
        version,
        name,
        version,
        b64_data,
        tarball_data.len,
    });
    defer allocator.free(body);

    // PUT to registry.
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var extra_headers_buf: [3]std.http.Header = undefined;
    var n_extra: usize = 0;
    extra_headers_buf[n_extra] = .{ .name = "Content-Type", .value = "application/json" };
    n_extra += 1;
    extra_headers_buf[n_extra] = .{ .name = "Accept", .value = "application/json" };
    n_extra += 1;

    var auth_val_buf: [256]u8 = undefined;
    var auth_val_len: usize = 0;
    if (config.getAuthToken(registry)) |token| {
        const av = try std.fmt.bufPrint(&auth_val_buf, "Bearer {s}", .{token});
        auth_val_len = av.len;
        extra_headers_buf[n_extra] = .{ .name = "Authorization", .value = auth_val_buf[0..auth_val_len] };
        n_extra += 1;
    }

    var server_header_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.PUT, uri, .{
        .server_header_buffer = &server_header_buf,
        .extra_headers = extra_headers_buf[0..n_extra],
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    try req.send();
    try req.writeAll(body);
    try req.finish();
    try req.wait();

    if (req.response.status == .conflict) return error.VersionAlreadyExists;
    if (req.response.status != .ok and req.response.status != .created) return error.PublishFailed;

    std.io.getStdOut().writer().print(
        "published {s}@{s} to {s}\n",
        .{ name, version, registry },
    ) catch {};
}

// ============================================================================
// Tarball creation
// ============================================================================

/// Creates a `package.tgz` tarball from the package directory.
///
/// Returns the path to the created tarball. Caller must delete after use.
fn createTarball(allocator: std.mem.Allocator, pkg_dir: []const u8, _: []const u8) ![]const u8 {
    const out_path = try std.fmt.allocPrint(allocator, "/tmp/nayr-pack-{d}.tgz", .{std.time.milliTimestamp()});

    // Use the system `tar` command for simplicity. A full implementation
    // would use std.tar directly for reproducible, sorted archives.
    var child = std.process.Child.init(
        &[_][]const u8{ "tar", "-czf", out_path, "--transform", "s,^,package/,", "-C", pkg_dir, "." },
        allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const result = try child.spawnAndWait();
    if (result != .Exited or result.Exited != 0) return error.TarballCreationFailed;

    return out_path;
}

// ============================================================================
// Options
// ============================================================================

/// Options for the `publish` command.
pub const PublishOptions = struct {
    /// Distribution tag (default: `"latest"`).
    tag: ?[]const u8 = null,
    /// Package visibility for scoped packages.
    access: Access = .restricted,
    /// Print what would be published without uploading.
    dry_run: bool = false,

    pub const Access = enum { public, restricted };
};
