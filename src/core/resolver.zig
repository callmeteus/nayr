//! Dependency Resolver
//!
//! Resolves a complete dependency graph starting from the root (and workspace)
//! `package.json` files. The resolution pipeline is:
//!
//!   1. Read the existing lockfile (nayr.lock or yarn.lock v1).
//!   2. Parse all package.json manifests (root + workspaces).
//!   3. For each dependency:
//!        a. Workspace packages: resolve locally (no network).
//!        b. Lockfile hit: use the locked version if it satisfies the range.
//!        c. Git dependencies: resolve via `git ls-remote`, respecting .nayrrc.
//!        d. Registry: fetch metadata and apply `maxSatisfying`.
//!   4. Apply `resolutions` field overrides.
//!   5. Recurse for transitive dependencies (BFS, cycle-safe).
//!
//! The resolver is designed to be called once per `nayr install` invocation.
//! It is single-threaded (BFS queue) because dependency resolution is
//! inherently sequential (you need A's version to know what B to resolve).
//! Network I/O (registry metadata fetches) is the only concurrent part,
//! implemented via a thread pool in the fetcher stage.

const std = @import("std");
const semver = @import("../semver/parser.zig");
const json_util = @import("../util/json.zig");
const lockfile_types = @import("../lockfile/types.zig");
const yarn_v1 = @import("../lockfile/yarn_v1.zig");
const nayr_fmt = @import("../lockfile/nayr_format.zig");
const registry_client = @import("../registry/client.zig");
const config_types = @import("../config/types.zig");
const ws_discovery = @import("../workspace/discovery.zig");
const ws_resolver = @import("../workspace/resolver.zig");
const PackageJson = json_util.PackageJson;
const Lockfile = lockfile_types.Lockfile;
const Config = config_types.Config;

// ============================================================================
// Resolved package
// ============================================================================

/// A fully resolved package, ready for the fetch and link phases.
pub const ResolvedPackage = struct {
    /// Package name.
    name: []const u8,
    /// Exact resolved version.
    version: []const u8,
    /// Tarball download URL (empty for workspace packages).
    tarball_url: []const u8,
    /// Integrity hash.
    integrity: []const u8,
    /// Registry URL where the package lives.
    registry: []const u8,
    /// Whether this is a workspace package (symlinked, not downloaded).
    is_workspace: bool,
    /// Whether this is a git dependency.
    is_git: bool,
    /// Resolved runtime dependencies (name → range).
    dependencies: std.StringHashMapUnmanaged([]const u8),
    /// Resolved optional dependencies.
    optional_dependencies: std.StringHashMapUnmanaged([]const u8),
};

// ============================================================================
// Resolution result
// ============================================================================

/// The output of a full resolution pass.
pub const ResolutionResult = struct {
    /// All resolved packages, keyed by `<name>@<version>`.
    packages: std.StringHashMapUnmanaged(ResolvedPackage),
    /// The updated lockfile (to be written to disk).
    lockfile: Lockfile,
    /// Allocator used for all result data.
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResolutionResult) void {
        // Free each ResolvedPackage's string fields and dependency maps.
        var it = self.packages.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            var pkg = kv.value_ptr.*;
            self.allocator.free(key);
            self.allocator.free(pkg.name);
            self.allocator.free(pkg.version);
            if (pkg.tarball_url.len > 0) self.allocator.free(pkg.tarball_url);
            if (pkg.integrity.len > 0) self.allocator.free(pkg.integrity);
            if (pkg.registry.len > 0) self.allocator.free(pkg.registry);
            var dep_it = pkg.dependencies.iterator();
            while (dep_it.next()) |dep| {
                self.allocator.free(dep.key_ptr.*);
                self.allocator.free(dep.value_ptr.*);
            }
            pkg.dependencies.deinit(self.allocator);
            var opt_it = pkg.optional_dependencies.iterator();
            while (opt_it.next()) |dep| {
                self.allocator.free(dep.key_ptr.*);
                self.allocator.free(dep.value_ptr.*);
            }
            pkg.optional_dependencies.deinit(self.allocator);
        }
        self.packages.deinit(self.allocator);
        self.lockfile.deinit(self.allocator);
    }
};

// ============================================================================
// Resolver options
// ============================================================================

/// Controls the resolver's behaviour.
pub const ResolverOptions = struct {
    /// Abort if the lockfile would change (CI safe-guard).
    frozen_lockfile: bool = false,
    /// Skip devDependencies.
    production: bool = false,
    /// Skip optionalDependencies.
    ignore_optional: bool = false,
    /// Force re-resolution even if lockfile is up-to-date.
    force: bool = false,
    /// Include only devDependencies.
    dev_only: bool = false,
};

// ============================================================================
// Resolver
// ============================================================================

/// Resolves all dependencies for the project.
///
/// ## Parameters
/// - `allocator`: All resolution data is allocated here.
/// - `root_dir`: Absolute path to the project root.
/// - `config`: Merged configuration (registries, auth, git settings).
/// - `opts`: Resolution options.
pub fn resolve(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    config: *const Config,
    opts: ResolverOptions,
) !ResolutionResult {
    // --- Load existing lockfile ---
    const nayr_lock_path = try std.fs.path.join(allocator, &.{ root_dir, "nayr.lock" });
    defer allocator.free(nayr_lock_path);
    const yarn_lock_path = try std.fs.path.join(allocator, &.{ root_dir, "yarn.lock" });
    defer allocator.free(yarn_lock_path);

    var existing_lock: Lockfile = blk: {
        // Prefer nayr.lock; fall back to yarn.lock v1 for migration.
        if (std.fs.accessAbsolute(nayr_lock_path, .{})) |_| {
            break :blk try nayr_fmt.parseFile(allocator, nayr_lock_path);
        } else |_| {}
        if (std.fs.accessAbsolute(yarn_lock_path, .{})) |_| {
            break :blk try yarn_v1.parseFile(allocator, yarn_lock_path);
        } else |_| {}
        break :blk Lockfile.init();
    };
    defer existing_lock.deinit(allocator);

    // --- Discover workspaces ---
    const workspaces = try ws_discovery.discover(allocator, root_dir);
    var ws_res = try ws_resolver.WorkspaceResolver.init(allocator, workspaces);

    // --- Load root manifest ---
    const root_manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "package.json" });
    defer allocator.free(root_manifest_path);
    var root_manifest = try json_util.parseFile(allocator, root_manifest_path);
    defer root_manifest.deinit(allocator);

    // --- Build registry client ---
    var client = registry_client.RegistryClient.init(allocator, config);
    defer client.deinit();

    // --- Collect seed dependencies ---
    var queue = std.ArrayList(DepRequest).init(allocator);
    defer queue.deinit();

    var resolved_set = std.StringHashMapUnmanaged(ResolvedPackage){};
    var visited = std.StringHashMapUnmanaged(void){};
    defer {
        var vis_it = visited.keyIterator();
        while (vis_it.next()) |k| allocator.free(k.*);
        visited.deinit(allocator);
    }

    // Seed from root manifest.
    try enqueueDeps(allocator, &queue, &root_manifest, opts);

    // Seed from each workspace manifest.
    for (workspaces) |*ws| {
        try enqueueDeps(allocator, &queue, &ws.manifest, opts);
    }

    // Apply `resolutions` overrides.
    var overrides = std.StringHashMapUnmanaged([]const u8){};
    defer overrides.deinit(allocator);
    var ov_it = root_manifest.resolutions.iterator();
    while (ov_it.next()) |kv| {
        try overrides.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
    }

    // --- BFS resolution loop ---
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const req = queue.items[qi];

        // Skip if already resolved.
        const dedupe_key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ req.name, req.range });
        defer allocator.free(dedupe_key);
        if (visited.contains(dedupe_key)) continue;
        try visited.put(allocator, try allocator.dupe(u8, dedupe_key), {});

        // Apply resolutions override if present.
        const effective_range = overrides.get(req.name) orelse req.range;

        // 1. Try workspace resolution.
        if (ws_res.resolve(req.name, effective_range)) |ws_pkg| {
            const rp = ResolvedPackage{
                .name = req.name,
                // Dupe version so we can free workspace manifests after the loop.
                .version = try allocator.dupe(u8, ws_pkg.manifest.version orelse "0.0.0"),
                .tarball_url = "",
                .integrity = "",
                .registry = "",
                .is_workspace = true,
                .is_git = false,
                .dependencies = .{},
                .optional_dependencies = .{},
            };
            const key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ rp.name, rp.version });
            try resolved_set.put(allocator, key, rp);
            continue;
        }

        // 2. Try lockfile hit.
        const lock_key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ req.name, effective_range });
        defer allocator.free(lock_key);
        if (!opts.force) {
            if (existing_lock.get(lock_key)) |entry| {
                if (semver.satisfies(allocator, entry.version, effective_range)) {
                    const rp = try resolvedFromLockEntry(allocator, req.name, entry, config);
                    const key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ rp.name, rp.version });
                    try resolved_set.put(allocator, key, rp);
                    // Enqueue transitive deps.
                    try enqueueMapDeps(allocator, &queue, &entry.dependencies, false);
                    try enqueueMapDeps(allocator, &queue, &entry.optional_dependencies, opts.ignore_optional);
                    continue;
                }
            }
        }

        // 3. Git dependency.
        if (isGitDep(effective_range)) {
            if (opts.frozen_lockfile) return error.FrozenLockfileChanged;
            const rp = try resolveGitDep(allocator, req.name, effective_range, config);
            const key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ rp.name, rp.version });
            try resolved_set.put(allocator, key, rp);
            continue;
        }

        // 4. Registry fetch.
        if (opts.frozen_lockfile) return error.FrozenLockfileChanged;

        const meta = client.fetchMetadata(req.name) catch |err| {
            if (req.optional) continue; // optional dep - skip on failure
            return err;
        };
        defer {
            var m = meta;
            m.deinit(allocator);
        }

        // Collect all version strings for maxSatisfying.
        var version_strs = try std.ArrayList([]const u8).initCapacity(allocator, meta.versions.count());
        var v_it = meta.versions.keyIterator();
        while (v_it.next()) |k| try version_strs.append(k.*);
        defer version_strs.deinit();

        const latest = meta.dist_tags.get("latest");
        const best_ver = semver.maxSatisfying(allocator, version_strs.items, effective_range, latest) orelse {
            if (req.optional) continue;
            return error.NoMatchingVersion;
        };

        const ver_info = meta.versions.get(best_ver).?;
        const rp = ResolvedPackage{
            .name = try allocator.dupe(u8, req.name),
            .version = try allocator.dupe(u8, ver_info.version),
            .tarball_url = try allocator.dupe(u8, ver_info.tarball),
            .integrity = try allocator.dupe(u8, ver_info.integrity),
            .registry = try allocator.dupe(u8, config.getRegistry(extractScope(req.name))),
            .is_workspace = false,
            .is_git = false,
            .dependencies = .{},
            .optional_dependencies = .{},
        };

        const key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ rp.name, rp.version });
        try resolved_set.put(allocator, key, rp);

        // Enqueue transitive deps.
        try enqueueMapDeps(allocator, &queue, &ver_info.dependencies, false);
        try enqueueMapDeps(allocator, &queue, &ver_info.optional_dependencies, opts.ignore_optional);
    }

    // Free queue items (names and ranges were duped during enqueue).
    for (queue.items) |req| {
        allocator.free(req.name);
        allocator.free(req.range);
    }

    // WorkspaceResolver holds pointers into workspaces - free it before workspaces.
    ws_res.deinit();

    // Free workspace manifests and paths now that the BFS loop is done.
    for (workspaces) |*ws| {
        allocator.free(ws.path);
        allocator.free(ws.rel_path);
        ws.manifest.deinit(allocator);
    }
    allocator.free(workspaces);

    // --- Build the new lockfile ---
    const new_lock = try buildLockfile(allocator, &resolved_set);

    return ResolutionResult{
        .packages = resolved_set,
        .lockfile = new_lock,
        .allocator = allocator,
    };
}

// ============================================================================
// Internal helpers
// ============================================================================

const DepRequest = struct {
    name: []const u8,
    range: []const u8,
    optional: bool,
};

fn enqueueDeps(
    allocator: std.mem.Allocator,
    queue: *std.ArrayList(DepRequest),
    manifest: *const PackageJson,
    opts: ResolverOptions,
) !void {
    // All strings are copied so that manifests can be freed after enqueueing
    // without leaving dangling pointers in the queue.
    if (!opts.production) {
        var it = manifest.dev_dependencies.iterator();
        while (it.next()) |kv| {
            try queue.append(.{
                .name = try allocator.dupe(u8, kv.key_ptr.*),
                .range = try allocator.dupe(u8, kv.value_ptr.*),
                .optional = false,
            });
        }
    }

    var it = manifest.dependencies.iterator();
    while (it.next()) |kv| {
        try queue.append(.{
            .name = try allocator.dupe(u8, kv.key_ptr.*),
            .range = try allocator.dupe(u8, kv.value_ptr.*),
            .optional = false,
        });
    }

    if (!opts.ignore_optional) {
        var oit = manifest.optional_dependencies.iterator();
        while (oit.next()) |kv| {
            try queue.append(.{
                .name = try allocator.dupe(u8, kv.key_ptr.*),
                .range = try allocator.dupe(u8, kv.value_ptr.*),
                .optional = true,
            });
        }
    }
}

fn enqueueMapDeps(
    allocator: std.mem.Allocator,
    queue: *std.ArrayList(DepRequest),
    map: *const std.StringHashMapUnmanaged([]const u8),
    skip: bool,
) !void {
    if (skip) return;
    var it = map.iterator();
    while (it.next()) |kv| {
        try queue.append(.{
            .name = try allocator.dupe(u8, kv.key_ptr.*),
            .range = try allocator.dupe(u8, kv.value_ptr.*),
            .optional = false,
        });
    }
}

fn resolvedFromLockEntry(
    allocator: std.mem.Allocator,
    name: []const u8,
    entry: *const lockfile_types.LockfileEntry,
    config: *const Config,
) !ResolvedPackage {
    return ResolvedPackage{
        .name = try allocator.dupe(u8, name),
        .version = try allocator.dupe(u8, entry.version),
        .tarball_url = try allocator.dupe(u8, entry.resolved),
        .integrity = try allocator.dupe(u8, entry.integrity),
        .registry = try allocator.dupe(u8, config.getRegistry(extractScope(name))),
        .is_workspace = false,
        .is_git = false,
        .dependencies = .{},
        .optional_dependencies = .{},
    };
}

/// Returns true when `range` is a git dependency specifier.
fn isGitDep(range: []const u8) bool {
    return std.mem.startsWith(u8, range, "git+") or
        std.mem.startsWith(u8, range, "git://") or
        std.mem.startsWith(u8, range, "github:") or
        (std.mem.startsWith(u8, range, "https://github.com") and !std.mem.endsWith(u8, range, ".tgz"));
}

/// Resolves a git dependency, respecting the `.nayrrc` pin-hash config.
///
/// Uses `git ls-remote` to query the remote HEAD. If `shouldPinGitHash` is
/// true, the resolved hash is stored in the lockfile. If false, the entry
/// is marked as always-stale so it re-resolves on the next install.
fn resolveGitDep(
    allocator: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
    config: *const Config,
) !ResolvedPackage {
    // Extract org and repo from the URL.
    const org_repo = extractGitOrgRepo(url);
    const should_pin = config.shouldPinGitHash(org_repo[0], org_repo[1]);

    // Run `git ls-remote <url> HEAD` to get the current commit hash.
    var head_hash: []const u8 = "";
    if (should_pin) {
        head_hash = resolveGitHash(allocator, url) catch "";
    }

    // The "version" for a git dep is the commit hash (when pinned) or "HEAD".
    const version = if (head_hash.len > 0)
        try std.fmt.allocPrint(allocator, "git+{s}#{s}", .{ url, head_hash })
    else
        try allocator.dupe(u8, url);

    return ResolvedPackage{
        .name = try allocator.dupe(u8, name),
        .version = version,
        .tarball_url = try allocator.dupe(u8, url),
        .integrity = "",
        .registry = "",
        .is_workspace = false,
        .is_git = true,
        .dependencies = .{},
        .optional_dependencies = .{},
    };
}

/// Runs `git ls-remote <url> HEAD` and returns the commit hash.
fn resolveGitHash(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    // Strip `git+` prefix if present.
    const clean_url = if (std.mem.startsWith(u8, url, "git+")) url[4..] else url;

    var child = std.process.Child.init(
        &[_][]const u8{ "git", "ls-remote", clean_url, "HEAD" },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 256);
    _ = try child.wait();

    // Output format: "<hash>\tHEAD\n"
    const tab = std.mem.indexOfScalar(u8, stdout, '\t') orelse {
        allocator.free(stdout);
        return error.GitHashNotFound;
    };
    const hash = try allocator.dupe(u8, stdout[0..tab]);
    allocator.free(stdout);
    return hash;
}

/// Extracts (org, repo) from a GitHub URL.
///
/// Returns `("", "")` for non-GitHub URLs.
fn extractGitOrgRepo(url: []const u8) [2][]const u8 {
    // github.com/org/repo or https://github.com/org/repo
    const gh_prefix = "github.com/";
    const start = std.mem.indexOf(u8, url, gh_prefix) orelse return .{ "", "" };
    const rest = url[start + gh_prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .{ rest, "" };
    return .{ rest[0..slash], rest[slash + 1 ..] };
}

fn extractScope(name: []const u8) ?[]const u8 {
    if (name.len == 0 or name[0] != '@') return null;
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return null;
    return name[0..slash];
}

fn buildLockfile(
    allocator: std.mem.Allocator,
    packages: *const std.StringHashMapUnmanaged(ResolvedPackage),
) !Lockfile {
    var entries = std.ArrayList(lockfile_types.LockfileEntry).init(allocator);
    var pattern_map = std.StringHashMapUnmanaged(usize){};

    var it = packages.iterator();
    while (it.next()) |kv| {
        const pkg = kv.value_ptr;
        const pattern = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ pkg.name, pkg.version });

        // Heap-allocate the patterns array so that the slice pointer survives
        // beyond this loop iteration (stack-allocated &.{pattern} would be UB).
        const patterns = try allocator.alloc([]const u8, 1);
        patterns[0] = pattern;

        const entry = lockfile_types.LockfileEntry{
            .patterns = patterns,
            .version = try allocator.dupe(u8, pkg.version),
            .resolved = try allocator.dupe(u8, pkg.tarball_url),
            .integrity = try allocator.dupe(u8, pkg.integrity),
        };
        const idx = entries.items.len;
        try pattern_map.put(allocator, pattern, idx);
        try entries.append(entry);
    }

    return Lockfile{
        .pattern_map = pattern_map,
        .entries = try entries.toOwnedSlice(),
        .workspaces = .{},
    };
}
