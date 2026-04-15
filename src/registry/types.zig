//! Registry API Types
//!
//! Data structures returned by the npm registry API. The registry speaks
//! JSON over HTTPS; these structs mirror the relevant fields of the responses.

const std = @import("std");

// ============================================================================
// PackageMetadata
// ============================================================================

/// The full metadata document returned by `GET /<package-name>`.
///
/// The registry returns a document with all versions and their details.
/// nayr only parses the fields it needs for dependency resolution.
pub const PackageMetadata = struct {
    /// Package name.
    name: []const u8,

    /// Map from version string → `VersionInfo`.
    versions: std.StringHashMapUnmanaged(VersionInfo),

    /// Distribution tags (e.g. `latest` → `"1.2.3"`).
    dist_tags: std.StringHashMapUnmanaged([]const u8),

    pub fn deinit(self: *PackageMetadata, allocator: std.mem.Allocator) void {
        var vit = self.versions.iterator();
        while (vit.next()) |kv| {
            // The map key is the same pointer as kv.value_ptr.*.version,
            // so it is freed inside deinit() below - do NOT free it here.
            kv.value_ptr.deinit(allocator);
        }
        self.versions.deinit(allocator);
        var dit = self.dist_tags.iterator();
        while (dit.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        self.dist_tags.deinit(allocator);
        allocator.free(self.name);
    }
};

// ============================================================================
// VersionInfo
// ============================================================================

/// Metadata for one specific version of a package.
pub const VersionInfo = struct {
    /// Version string.
    version: []const u8,
    /// Tarball download URL.
    tarball: []const u8,
    /// Integrity hash (sha512 preferred, sha1 fallback).
    integrity: []const u8 = "",
    /// Unpacked size in bytes (for progress reporting).
    unpacked_size: u64 = 0,
    /// Runtime dependencies (name → range).
    dependencies: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Optional dependencies.
    optional_dependencies: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Peer dependencies.
    peer_dependencies: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Bin entries.
    bin: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn deinit(self: *VersionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        allocator.free(self.tarball);
        if (self.integrity.len > 0) allocator.free(self.integrity);
        freeStrMap(allocator, &self.dependencies);
        freeStrMap(allocator, &self.optional_dependencies);
        freeStrMap(allocator, &self.peer_dependencies);
        freeStrMap(allocator, &self.bin);
    }
};

/// Frees all key-value string pairs inside a StringHashMapUnmanaged, then the map.
fn freeStrMap(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |kv| {
        allocator.free(kv.key_ptr.*);
        allocator.free(kv.value_ptr.*);
    }
    map.deinit(allocator);
}


// ============================================================================
// AuditAdvisory
// ============================================================================

/// A security advisory returned by the bulk audit API.
pub const AuditAdvisory = struct {
    /// Advisory ID (npm registry numeric ID).
    id: u64,
    /// Human-readable title.
    title: []const u8,
    /// Severity: "critical", "high", "moderate", "low", "info".
    severity: []const u8,
    /// Affected package name.
    module_name: []const u8,
    /// Vulnerable version range.
    vulnerable_versions: []const u8,
    /// Patched version range (empty = no patch available).
    patched_versions: []const u8,
    /// Advisory URL.
    url: []const u8,
};
