//! Lockfile Types
//!
//! Shared types used by both the yarn.lock v1 parser and the nayr.lock
//! reader/writer. The `LockfileEntry` struct is the canonical in-memory
//! representation of a locked package, regardless of which format it came from.

const std = @import("std");

// ============================================================================
// LockfileEntry
// ============================================================================

/// A single entry in a lockfile, representing one resolved package.
///
/// A single entry may cover multiple version patterns (when two ranges resolve
/// to the same version), stored in the `patterns` slice.
///
/// Example (yarn.lock):
///
/// ```
/// lodash@^4.17.0, lodash@^4.17.21:
///   version "4.17.21"
///   resolved "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz#..."
///   integrity sha512-v2kDEe...
/// ```
pub const LockfileEntry = struct {
    /// All version patterns that map to this entry (e.g. "^4.17.0", "^4.17.21").
    patterns: []const []const u8,

    /// Resolved version string (e.g. "4.17.21").
    version: []const u8,

    /// Download URL for the tarball.
    resolved: []const u8 = "",

    /// Integrity hash. Prefer sha512 (format: "sha512-<base64>").
    /// May be sha1 for older entries from yarn.lock v1.
    integrity: []const u8 = "",

    /// Resolved runtime dependencies (name → version range).
    dependencies: std.StringHashMapUnmanaged([]const u8) = .{},

    /// Resolved optional dependencies.
    optional_dependencies: std.StringHashMapUnmanaged([]const u8) = .{},

    /// Frees all memory owned by this entry.
    pub fn deinit(self: *LockfileEntry, allocator: std.mem.Allocator) void {
        for (self.patterns) |p| allocator.free(p);
        allocator.free(self.patterns);
        if (self.version.len > 0) allocator.free(self.version);
        if (self.resolved.len > 0) allocator.free(self.resolved);
        if (self.integrity.len > 0) allocator.free(self.integrity);

        var dep_it = self.dependencies.iterator();
        while (dep_it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        self.dependencies.deinit(allocator);

        var opt_it = self.optional_dependencies.iterator();
        while (opt_it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        self.optional_dependencies.deinit(allocator);
    }
};

// ============================================================================
// Lockfile (in-memory)
// ============================================================================

/// The complete in-memory representation of a lockfile.
///
/// The `entries` map uses the pattern string (e.g. "lodash@^4.17.0") as the
/// key and points to the corresponding entry.
pub const Lockfile = struct {
    /// Map from pattern string to entry index in `entries`.
    pattern_map: std.StringHashMapUnmanaged(usize),

    /// All unique entries.
    entries: []LockfileEntry,

    /// Workspace metadata embedded in the lockfile (nayr.lock only).
    workspaces: std.StringHashMapUnmanaged(WorkspaceInfo),

    pub const WorkspaceInfo = struct {
        location: []const u8,
        version: []const u8,
    };

    /// Creates an empty lockfile.
    pub fn init() Lockfile {
        return .{
            .pattern_map = .{},
            .entries = &.{},
            .workspaces = .{},
        };
    }

    /// Looks up an entry by its pattern string.
    ///
    /// ## Returns
    /// A pointer to the entry, or `null` if not found.
    pub fn get(self: *const Lockfile, pattern: []const u8) ?*const LockfileEntry {
        const idx = self.pattern_map.get(pattern) orelse return null;
        return &self.entries[idx];
    }

    /// Frees all memory owned by the lockfile.
    pub fn deinit(self: *Lockfile, allocator: std.mem.Allocator) void {
        // Keys of pattern_map are borrowed from entries[].patterns - do not free.
        self.pattern_map.deinit(allocator);
        for (self.entries) |*e| e.deinit(allocator);
        allocator.free(self.entries);
        var ws_it = self.workspaces.iterator();
        while (ws_it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*.location);
            allocator.free(kv.value_ptr.*.version);
        }
        self.workspaces.deinit(allocator);
    }

    /// Returns true when two lockfiles describe the same resolved graph.
    ///
    /// Pattern order and entry order are ignored; workspace metadata must match.
    pub fn semanticEqual(a: *const Lockfile, b: *const Lockfile) bool {
        if (a.entries.len != b.entries.len) return false;
        if (a.workspaces.count() != b.workspaces.count()) return false;

        for (a.entries) |*a_entry| {
            var matched = false;
            for (b.entries) |*b_entry| {
                if (lockfileEntryEqual(a_entry, b_entry)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }

        var ws_it = a.workspaces.iterator();
        while (ws_it.next()) |kv| {
            const other = b.workspaces.get(kv.key_ptr.*) orelse return false;
            if (!std.mem.eql(u8, kv.value_ptr.*.location, other.location)) return false;
            if (!std.mem.eql(u8, kv.value_ptr.*.version, other.version)) return false;
        }

        return true;
    }
};

fn lockfileEntryEqual(a: *const LockfileEntry, b: *const LockfileEntry) bool {
    if (!std.mem.eql(u8, a.version, b.version)) return false;
    if (!std.mem.eql(u8, a.resolved, b.resolved)) return false;
    if (!std.mem.eql(u8, a.integrity, b.integrity)) return false;
    if (a.patterns.len != b.patterns.len) return false;
    if (!stringMapEqual(&a.dependencies, &b.dependencies)) return false;
    if (!stringMapEqual(&a.optional_dependencies, &b.optional_dependencies)) return false;

    for (a.patterns) |pat| {
        var found = false;
        for (b.patterns) |other_pat| {
            if (std.mem.eql(u8, pat, other_pat)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    return true;
}

fn stringMapEqual(
    a: *const std.StringHashMapUnmanaged([]const u8),
    b: *const std.StringHashMapUnmanaged([]const u8),
) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |kv| {
        const other = b.get(kv.key_ptr.*) orelse return false;
        if (!std.mem.eql(u8, kv.value_ptr.*, other)) return false;
    }
    return true;
}
