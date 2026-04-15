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
//! ## Parallelism
//!
//! Resolution uses a **FIFO worker-pool BFS**. N worker threads live for the
//! entire resolve() call. The main thread classifies each dep request:
//!
//!   - Workspace / lockfile / git: resolved immediately (no I/O).
//!   - Registry: pushed to the fetch queue for a free worker.
//!
//! Workers fetch metadata and push results back via a result queue. The main
//! thread processes results as they arrive and immediately queues transitive
//! deps - no waiting for an entire "wave" to finish. This gives true FIFO
//! pipeline behaviour: deeper levels start fetching as soon as their parent
//! result is ready, not after all siblings complete.

const std = @import("std");
const semver = @import("../semver/parser.zig");
const json_util = @import("../util/json.zig");
const lockfile_types = @import("../lockfile/types.zig");
const yarn_v1 = @import("../lockfile/yarn_v1.zig");
const nayr_fmt = @import("../lockfile/nayr_format.zig");
const registry_client = @import("../registry/client.zig");
const reg_types = @import("../registry/types.zig");
const config_types = @import("../config/types.zig");
const ws_discovery = @import("../workspace/discovery.zig");
const ws_resolver = @import("../workspace/resolver.zig");
const output = @import("../util/output.zig");
const platform = @import("../util/platform.zig");
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
    /// Tarball download URL (empty for workspace/linked packages).
    tarball_url: []const u8,
    /// Integrity hash.
    integrity: []const u8,
    /// Registry URL where the package lives.
    registry: []const u8,
    /// Whether this is a workspace package (symlinked, not downloaded).
    is_workspace: bool,
    /// Whether this is a git dependency.
    is_git: bool,
    /// Whether this package was resolved from a local link registry entry
    /// (`nayr link` or inherited from Yarn). When true, `tarball_url` holds
    /// the absolute path to the development checkout instead of a download URL.
    is_linked: bool = false,
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
    /// Number of parallel metadata-fetch threads per wave.
    concurrency: u32 = 32,
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
/// - `writer`: Output event sink for progress reporting.
pub fn resolve(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    config: *const Config,
    opts: ResolverOptions,
    writer: output.Writer,
) !ResolutionResult {
    // --- Load existing lockfile ---
    const nayr_lock_path = try std.fs.path.join(allocator, &.{ root_dir, "nayr.lock" });
    defer allocator.free(nayr_lock_path);
    const yarn_lock_path = try std.fs.path.join(allocator, &.{ root_dir, "yarn.lock" });
    defer allocator.free(yarn_lock_path);

    var existing_lock: Lockfile = blk: {
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

    // Thread-safe allocator: workers allocate metadata on the same GPA.
    var ts_wrapper = std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
    const ts_alloc = ts_wrapper.allocator();

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

    try enqueueDeps(allocator, &queue, &root_manifest, opts);
    for (workspaces) |*ws| {
        try enqueueDeps(allocator, &queue, &ws.manifest, opts);
    }

    var overrides = std.StringHashMapUnmanaged([]const u8){};
    defer overrides.deinit(allocator);
    var ov_it = root_manifest.resolutions.iterator();
    while (ov_it.next()) |kv| {
        try overrides.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
    }

    // Load the combined nayr + yarn link registry once, before the BFS loop.
    // Keys and values are owned by this map; freed below.
    var links_map = try loadLinksRegistry(allocator);
    defer {
        var lm_it = links_map.iterator();
        while (lm_it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        links_map.deinit(allocator);
    }

    // --- FIFO parallel BFS with persistent worker pool ---
    //
    // `queue` is the append-only BFS queue; `qi` is the next unclassified index.
    // Fast paths (workspace / lockfile / git) are resolved inline by the main
    // thread. Registry packages are pushed to `ch.fetch_items`; workers fetch
    // their metadata and push `FetchResult` to `ch.result_items`.
    //
    // Main thread loop:
    //   1. Drain all currently-available queue items (fast paths inline,
    //      registry pushed to workers → in_flight++).
    //   2. Wait for a result when in_flight > 0 and queue is exhausted.
    //   3. Process result, enqueue transitive deps → back to step 1.
    //
    // Termination: qi >= queue.items.len AND in_flight == 0.

    var ch = FifoChannels{
        .ts_alloc = ts_alloc,
        .config = config,
        .fetch_mutex = .{},
        .fetch_cond = .{},
        .fetch_items = .{},
        .result_mutex = .{},
        .result_cond = .{},
        .result_items = .{},
        .shutdown = std.atomic.Value(bool).init(false),
    };

    const n_workers = opts.concurrency;
    const worker_threads = try allocator.alloc(std.Thread, n_workers);
    var workers_spawned: usize = 0;
    defer {
        ch.shutdown.store(true, .release);
        ch.fetch_cond.broadcast();
        for (worker_threads[0..workers_spawned]) |t| t.join();
        allocator.free(worker_threads);
        // Drain any buffered results left over from an early-exit on error.
        for (ch.result_items.items) |*r| {
            if (r.meta) |*m| m.deinit(allocator);
        }
        ch.result_items.deinit(allocator);
        ch.fetch_items.deinit(allocator);
    }
    for (worker_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, fifoWorker, .{&ch});
        workers_spawned += 1;
    }

    var qi: usize = 0;
    var in_flight: usize = 0; // items pushed to workers, results not yet processed

    while (qi < queue.items.len or in_flight > 0) {
        // --- Drain available queue items (fast paths inline) ---
        while (qi < queue.items.len) {
            const req = queue.items[qi];
            qi += 1;

            const dedupe_key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ req.name, req.range });
            defer allocator.free(dedupe_key);
            if (visited.contains(dedupe_key)) continue;
            try visited.put(allocator, try allocator.dupe(u8, dedupe_key), {});

            const effective_range = overrides.get(req.name) orelse req.range;

            // 1. Workspace hit.
            // NOTE: workspace packages (part of the current monorepo) are
            // handled here with highest priority. Link-registry packages
            // (external dev checkouts) are checked immediately after.
            if (ws_res.resolve(req.name, effective_range)) |ws_pkg| {
                const rp = ResolvedPackage{
                    .name = try allocator.dupe(u8, req.name),
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
                if (!resolved_set.contains(key)) {
                    try resolved_set.put(allocator, key, rp);
                } else {
                    allocator.free(key);
                    allocator.free(rp.version);
                }
                writer.emit(.{ .resolve_progress = .{
                    .resolved = @intCast(resolved_set.count()),
                    .total = @intCast(queue.items.len),
                    .name = req.name,
                } });
                continue;
            }

            // 1.5. Link registry hit - highest priority for external dev checkouts.
            //
            // If the package name is registered in the nayr or yarn link
            // registry, use the local development checkout unconditionally.
            // This matches Yarn Classic semantics: links override registry,
            // lockfile, and even version constraints. The developer controls
            // the version they're testing against.
            if (links_map.get(req.name)) |link_target| {
                // Read the local package.json to obtain the current version.
                const pkg_json_path = try std.fs.path.join(allocator, &.{ link_target, "package.json" });
                defer allocator.free(pkg_json_path);
                var local_manifest = json_util.parseFile(allocator, pkg_json_path) catch null;
                // Extract version into an owned string before freeing the manifest.
                var local_version_owned: []const u8 = try allocator.dupe(u8, "0.0.0");
                if (local_manifest) |*m| {
                    if (m.version) |v| {
                        allocator.free(local_version_owned);
                        local_version_owned = try allocator.dupe(u8, v);
                    }
                    m.deinit(allocator);
                }
                defer allocator.free(local_version_owned);
                const local_version = local_version_owned;

                const key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ req.name, local_version });
                if (!resolved_set.contains(key)) {
                    const rp = ResolvedPackage{
                        .name = try allocator.dupe(u8, req.name),
                        .version = try allocator.dupe(u8, local_version),
                        // Re-purpose tarball_url to store the checkout path.
                        // The fetcher skips is_workspace/is_linked packages.
                        .tarball_url = try allocator.dupe(u8, link_target),
                        .integrity = "",
                        .registry = "",
                        .is_workspace = true, // treated as workspace by linker
                        .is_git = false,
                        .is_linked = true,
                        .dependencies = .{},
                        .optional_dependencies = .{},
                    };
                    try resolved_set.put(allocator, key, rp);
                } else {
                    allocator.free(key);
                }
                writer.emit(.{ .resolve_progress = .{
                    .resolved = @intCast(resolved_set.count()),
                    .total = @intCast(queue.items.len),
                    .name = req.name,
                } });
                continue;
            }

            // 2. Lockfile hit.
            if (!opts.force) {
                const lock_key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ req.name, effective_range });
                defer allocator.free(lock_key);
                if (existing_lock.get(lock_key)) |entry| {
                    if (semver.satisfies(allocator, entry.version, effective_range)) {
                        const map_key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ req.name, entry.version });
                        if (resolved_set.contains(map_key)) {
                            allocator.free(map_key);
                        } else {
                            const rp = try resolvedFromLockEntry(allocator, req.name, entry, config);
                            try resolved_set.put(allocator, map_key, rp);
                        }
                        try enqueueMapDeps(allocator, &queue, &entry.dependencies, false);
                        try enqueueMapDeps(allocator, &queue, &entry.optional_dependencies, opts.ignore_optional);
                        writer.emit(.{ .resolve_progress = .{
                            .resolved = @intCast(resolved_set.count()),
                            .total = @intCast(queue.items.len),
                            .name = req.name,
                        } });
                        continue;
                    }
                }
            }

            // 3. Git dependency (serial - uncommon).
            if (isGitDep(effective_range)) {
                if (opts.frozen_lockfile) return error.FrozenLockfileChanged;
                const rp = try resolveGitDep(allocator, req.name, effective_range, config);
                const key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ rp.name, rp.version });
                if (resolved_set.contains(key)) {
                    allocator.free(key);
                    freeResolvedPackage(allocator, rp);
                } else {
                    try resolved_set.put(allocator, key, rp);
                }
                writer.emit(.{ .resolve_progress = .{
                    .resolved = @intCast(resolved_set.count()),
                    .total = @intCast(queue.items.len),
                    .name = req.name,
                } });
                continue;
            }

            // 4. Registry - hand off to the worker pool.
            if (opts.frozen_lockfile) return error.FrozenLockfileChanged;
            ch.fetch_mutex.lock();
            try ch.fetch_items.append(allocator, FetchJob{
                .name = req.name,
                .eff_range = effective_range,
                .optional = req.optional,
            });
            ch.fetch_mutex.unlock();
            ch.fetch_cond.signal();
            in_flight += 1;
        }

        if (in_flight == 0) break; // nothing left anywhere

        // --- Wait for the next result from a worker ---
        var result: FetchResult = blk: {
            ch.result_mutex.lock();
            defer ch.result_mutex.unlock();
            while (ch.result_items.items.len == 0) {
                ch.result_cond.wait(&ch.result_mutex);
            }
            break :blk ch.result_items.swapRemove(0);
        };
        in_flight -= 1;

        // result.meta is freed at every exit path of this block.
        defer if (result.meta) |*m| m.deinit(allocator);

        if (result.err) |err| {
            if (result.job.optional) continue;
            std.io.getStdErr().writer().print(
                "  warn  failed to resolve package: {s}\n",
                .{result.job.name},
            ) catch {};
            return err;
        }

        const meta = result.meta orelse continue;

        var version_strs = try std.ArrayList([]const u8).initCapacity(
            allocator,
            meta.versions.count(),
        );
        defer version_strs.deinit();
        var v_it = meta.versions.keyIterator();
        while (v_it.next()) |k| try version_strs.append(k.*);

        const latest = meta.dist_tags.get("latest");
        const best_ver = semver.maxSatisfying(
            allocator,
            version_strs.items,
            result.job.eff_range,
            latest,
        ) orelse {
            if (result.job.optional) continue;
            std.io.getStdErr().writer().print(
                "  warn  no version of {s} satisfies range \"{s}\"\n",
                .{ result.job.name, result.job.eff_range },
            ) catch {};
            return error.NoMatchingVersion;
        };

        const ver_info = meta.versions.get(best_ver).?;

        const key = try std.fmt.allocPrint(
            allocator,
            "{s}@{s}",
            .{ result.job.name, ver_info.version },
        );
        if (resolved_set.contains(key)) {
            allocator.free(key);
            try enqueueMapDeps(allocator, &queue, &ver_info.dependencies, false);
            try enqueueMapDeps(allocator, &queue, &ver_info.optional_dependencies, opts.ignore_optional);
            continue;
        }

        const rp = ResolvedPackage{
            .name = try allocator.dupe(u8, result.job.name),
            .version = try allocator.dupe(u8, ver_info.version),
            .tarball_url = try allocator.dupe(u8, ver_info.tarball),
            .integrity = try allocator.dupe(u8, ver_info.integrity),
            .registry = try allocator.dupe(u8, config.getRegistry(extractScope(result.job.name))),
            .is_workspace = false,
            .is_git = false,
            .dependencies = try copyStringMap(allocator, &ver_info.dependencies),
            .optional_dependencies = try copyStringMap(allocator, &ver_info.optional_dependencies),
        };
        try resolved_set.put(allocator, key, rp);

        // Transitive deps go into `queue`; the main loop's `qi` will reach
        // them and immediately push them to workers (true FIFO pipeline).
        try enqueueMapDeps(allocator, &queue, &ver_info.dependencies, false);
        try enqueueMapDeps(allocator, &queue, &ver_info.optional_dependencies, opts.ignore_optional);

        writer.emit(.{ .resolve_progress = .{
            .resolved = @intCast(resolved_set.count()),
            .total = @intCast(queue.items.len),
            .name = rp.name,
        } });
    }

    // Free queue items (names and ranges were duped during enqueue).
    for (queue.items) |req| {
        allocator.free(req.name);
        allocator.free(req.range);
    }

    ws_res.deinit();

    for (workspaces) |*ws| {
        allocator.free(ws.path);
        allocator.free(ws.rel_path);
        ws.manifest.deinit(allocator);
    }
    allocator.free(workspaces);

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

/// Frees a `ResolvedPackage` that was never inserted into `resolved_set`
/// (e.g. a duplicate that was discarded after the key check).
fn freeResolvedPackage(allocator: std.mem.Allocator, pkg: ResolvedPackage) void {
    allocator.free(pkg.name);
    allocator.free(pkg.version);
    if (pkg.tarball_url.len > 0) allocator.free(pkg.tarball_url);
    if (pkg.integrity.len > 0) allocator.free(pkg.integrity);
    if (pkg.registry.len > 0) allocator.free(pkg.registry);
    // deps maps are empty at construction time for git/lockfile packages.
}

/// Builds a `name → absolute_path` map from both the nayr links registry
/// (`~/.nayr/links/`) and the Yarn Classic registry (`~/.config/yarn/link/`).
///
/// nayr's registry takes precedence. Yarn entries are only added for names not
/// already present in nayr's registry.
///
/// All keys and values are owned by the caller (allocated with `allocator`).
/// The caller should free them by iterating the map.
fn loadLinksRegistry(
    allocator: std.mem.Allocator,
) !std.StringHashMapUnmanaged([]const u8) {
    var map = std.StringHashMapUnmanaged([]const u8){};

    const nayr_dir = platform.getLinksDir(allocator) catch return map;
    defer allocator.free(nayr_dir);
    try walkLinksIntoMap(allocator, nayr_dir, &map, false);

    const yarn_dir = platform.getYarnLinksDir(allocator) catch return map;
    defer allocator.free(yarn_dir);
    try walkLinksIntoMap(allocator, yarn_dir, &map, true); // skip_existing=true

    return map;
}

/// Walks `dir_path` (depth-2 for scoped packages) and inserts
/// `name → resolved_target` into `map`.
///
/// When `skip_existing` is true, entries whose name is already in the map are
/// not overwritten (used to give nayr's registry precedence over Yarn's).
fn walkLinksIntoMap(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    map: *std.StringHashMapUnmanaged([]const u8),
    skip_existing: bool,
) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .sym_link) {
            if (skip_existing and map.contains(entry.name)) continue;
            const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(full);
            const target = platform.readSymlinkAbsolute(allocator, full) catch continue;
            const name_owned = try allocator.dupe(u8, entry.name);
            try map.put(allocator, name_owned, target);
        } else if (entry.kind == .directory and entry.name[0] == '@') {
            const scope_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(scope_path);
            var sd = std.fs.openDirAbsolute(scope_path, .{ .iterate = true }) catch continue;
            defer sd.close();
            var sit = sd.iterate();
            while (try sit.next()) |se| {
                if (se.kind != .sym_link) continue;
                const scoped = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, se.name });
                if (skip_existing and map.contains(scoped)) {
                    allocator.free(scoped);
                    continue;
                }
                const full = try std.fs.path.join(allocator, &.{ scope_path, se.name });
                defer allocator.free(full);
                const target = platform.readSymlinkAbsolute(allocator, full) catch {
                    allocator.free(scoped);
                    continue;
                };
                try map.put(allocator, scoped, target);
            }
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
        .dependencies = try copyStringMap(allocator, &entry.dependencies),
        .optional_dependencies = try copyStringMap(allocator, &entry.optional_dependencies),
    };
}

/// Deep-copies a `StringHashMapUnmanaged([]const u8)` with owned keys and values.
fn copyStringMap(
    allocator: std.mem.Allocator,
    src: *const std.StringHashMapUnmanaged([]const u8),
) !std.StringHashMapUnmanaged([]const u8) {
    var dst = std.StringHashMapUnmanaged([]const u8){};
    var it = src.iterator();
    while (it.next()) |kv| {
        try dst.put(
            allocator,
            try allocator.dupe(u8, kv.key_ptr.*),
            try allocator.dupe(u8, kv.value_ptr.*),
        );
    }
    return dst;
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
    defer if (head_hash.len > 0) allocator.free(head_hash);

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

// ============================================================================
// FIFO worker-pool infrastructure
// ============================================================================

/// A registry metadata fetch job (main → worker).
const FetchJob = struct {
    /// Points into the BFS queue; valid for the lifetime of resolve().
    name: []const u8,
    /// Effective version range after `resolutions` overrides.
    eff_range: []const u8,
    optional: bool,
};

/// Result of a metadata fetch (worker → main).
const FetchResult = struct {
    job: FetchJob,
    /// Allocated on ts_alloc; caller must deinit.
    meta: ?reg_types.PackageMetadata,
    err: ?anyerror,
};

/// Shared channel state between the main thread and the worker pool.
const FifoChannels = struct {
    ts_alloc: std.mem.Allocator,
    config: *const Config,

    // Fetch queue: main pushes FetchJobs; workers pop and fetch.
    fetch_mutex: std.Thread.Mutex,
    fetch_cond: std.Thread.Condition,
    fetch_items: std.ArrayListUnmanaged(FetchJob),

    // Result queue: workers push FetchResults; main pops and processes.
    result_mutex: std.Thread.Mutex,
    result_cond: std.Thread.Condition,
    result_items: std.ArrayListUnmanaged(FetchResult),

    /// Set to true when workers should drain and exit.
    shutdown: std.atomic.Value(bool),
};

/// Persistent worker thread: pops FetchJobs, fetches metadata, pushes results.
fn fifoWorker(ch: *FifoChannels) void {
    var client = registry_client.RegistryClient.init(ch.ts_alloc, ch.config);
    defer client.deinit();

    while (true) {
        // Wait for a job (or shutdown signal).
        const job: FetchJob = blk: {
            ch.fetch_mutex.lock();
            defer ch.fetch_mutex.unlock();
            while (ch.fetch_items.items.len == 0) {
                if (ch.shutdown.load(.acquire)) return;
                ch.fetch_cond.wait(&ch.fetch_mutex);
            }
            // orderedRemove(0) preserves FIFO ordering.
            break :blk ch.fetch_items.orderedRemove(0);
        };

        var result = FetchResult{ .job = job, .meta = null, .err = null };
        if (client.fetchMetadata(job.name)) |meta| {
            result.meta = meta;
        } else |err| {
            result.err = err;
        }

        ch.result_mutex.lock();
        ch.result_items.append(ch.ts_alloc, result) catch {
            ch.result_mutex.unlock();
            return;
        };
        ch.result_mutex.unlock();
        ch.result_cond.signal();
    }
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

        var entry = lockfile_types.LockfileEntry{
            .patterns = patterns,
            .version = try allocator.dupe(u8, pkg.version),
            .resolved = try allocator.dupe(u8, pkg.tarball_url),
            .integrity = try allocator.dupe(u8, pkg.integrity),
        };

        // Copy runtime and optional dependency maps so subsequent installs
        // can enqueue transitive deps from the lockfile without re-fetching
        // metadata from the registry.
        var dep_it = pkg.dependencies.iterator();
        while (dep_it.next()) |dep_kv| {
            try entry.dependencies.put(
                allocator,
                try allocator.dupe(u8, dep_kv.key_ptr.*),
                try allocator.dupe(u8, dep_kv.value_ptr.*),
            );
        }
        var opt_it = pkg.optional_dependencies.iterator();
        while (opt_it.next()) |opt_kv| {
            try entry.optional_dependencies.put(
                allocator,
                try allocator.dupe(u8, opt_kv.key_ptr.*),
                try allocator.dupe(u8, opt_kv.value_ptr.*),
            );
        }

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
