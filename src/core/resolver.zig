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
//! Resolution uses **wave-based batch fetching**.  Each "wave" drains the BFS
//! queue, handling fast paths (workspace / lockfile / git) inline, then
//! dispatches all remaining registry requests as a SINGLE curl --parallel
//! invocation.  curl uses HTTP/2 multiplexing so all requests in a wave share
//! one TLS connection to the registry, eliminating per-request TLS handshake
//! overhead.  This is dramatically faster than the previous approach of
//! spawning one curl process per package.
//!
//! Waves correspond roughly to BFS depth levels of the dependency graph.
//! For a typical npm project this is 4-6 waves.

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
const output = @import("../util/output.zig");
const platform = @import("../util/platform.zig");
const IoTrace = @import("../util/io_trace.zig").IoTrace;
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
    /// Number of packages per curl --parallel chunk.
    /// Each chunk is one curl invocation; smaller values give more frequent
    /// progress updates at the cost of slightly more process spawns.
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

    // Maps "name@range" → "name@version".  Built as packages are resolved so
    // that buildLockfile can write the original request ranges as lockfile
    // patterns instead of the resolved version strings.  Lockfile lookups use
    // the range as key, so without this every install would be a full cache miss.
    var range_to_key = std.StringHashMapUnmanaged([]const u8){};
    defer {
        var rtk_it = range_to_key.iterator();
        while (rtk_it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        range_to_key.deinit(allocator);
    }

    // Collect names of all workspace packages (root + sub-workspaces).
    // These are always exempt from security checks — they're the developer's
    // own code, never downloaded from a registry or external git host.
    var workspace_names = std.StringHashMapUnmanaged(void){};
    defer workspace_names.deinit(allocator);
    if (root_manifest.name) |n| {
        try workspace_names.put(allocator, n, {});
    }
    for (workspaces) |*ws| {
        if (ws.manifest.name) |n| try workspace_names.put(allocator, n, {});
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

    // --- Wave-based parallel BFS ---
    //
    // Each wave:
    //   1. Drains the BFS queue, handling fast paths (workspace/lockfile/git)
    //      inline and accumulating registry requests into `pending_batch`.
    //   2. When the queue is exhausted for the wave, dispatches ALL pending
    //      registry requests as a single curl --parallel invocation using
    //      HTTP/2 multiplexing (one TLS connection, many streams).
    //   3. Processes all results and enqueues transitive deps into `queue`.
    //   4. Repeats until both `queue` and `pending_batch` are empty.
    //
    // This eliminates per-request curl process spawns and TLS handshakes.
    // For a project with 1000 registry-fetched packages and 5 BFS levels,
    // this means ~5 curl invocations instead of ~1000.

    var pending_batch = std.ArrayList(PendingFetch).init(allocator);
    defer pending_batch.deinit();

    var qi: usize = 0;

    while (qi < queue.items.len or pending_batch.items.len > 0) {
        // --- Drain the BFS queue ---
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
                // Read the local package.json to obtain the current version and
                // runtime dependencies. The deps are enqueued so that transitive
                // requirements of the linked package (e.g. TypeScript) are
                // installed in the consumer's node_modules and their bin stubs
                // (e.g. .bin/tsc) are created - matching Yarn Classic behaviour.
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
                    // Enqueue runtime deps before freeing (enqueueMapDeps dupes strings).
                    try enqueueMapDeps(allocator, &queue, &m.dependencies, false);
                    try enqueueMapDeps(allocator, &queue, &m.optional_dependencies, opts.ignore_optional);
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

                        // Record range → resolved key for lockfile pattern generation.
                        {
                            const rtk_pat = try allocator.dupe(u8, lock_key);
                            const rtk_val = try allocator.dupe(u8, map_key);
                            const gop = try range_to_key.getOrPut(allocator, rtk_pat);
                            if (gop.found_existing) {
                                allocator.free(rtk_pat); // old key kept in map
                                allocator.free(gop.value_ptr.*);
                            }
                            gop.value_ptr.* = rtk_val;
                        }

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

                // Security: git host allow-list.
                // Skipped for the developer's own packages (auto_link_patterns
                // or any workspace in this repo).
                if (!config.isExemptFromSecurity(req.name) and
                    !workspace_names.contains(req.name) and
                    !config.isGitHostAllowed(effective_range))
                {
                    const msg = try std.fmt.allocPrint(
                        allocator,
                        "security: git source not in allowed-git-hosts: {s} (required by {s})",
                        .{ effective_range, req.name },
                    );
                    defer allocator.free(msg);
                    writer.emit(.{ .err = msg });
                    return error.GitHostNotAllowed;
                }

                const rp = try resolveGitDep(allocator, req.name, effective_range, config);
                const key = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ rp.name, rp.version });

                // Record range → resolved key.
                {
                    const rtk_pat = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ req.name, effective_range });
                    const rtk_val = try allocator.dupe(u8, key);
                    const gop = try range_to_key.getOrPut(allocator, rtk_pat);
                    if (gop.found_existing) {
                        allocator.free(rtk_pat);
                        allocator.free(gop.value_ptr.*);
                    }
                    gop.value_ptr.* = rtk_val;
                }

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

            // 4. Registry - defer to the wave's batch.
            if (opts.frozen_lockfile) return error.FrozenLockfileChanged;

            // Security: registry allow-list.
            // Skipped for the developer's own packages (auto_link_patterns
            // or any workspace in this repo).
            if (!config.isExemptFromSecurity(req.name) and !workspace_names.contains(req.name)) {
                const registry_url = config.getRegistry(extractScope(req.name));
                if (!config.isRegistryAllowed(registry_url)) {
                    if (req.optional) continue;
                    const msg = try std.fmt.allocPrint(
                        allocator,
                        "security: registry not in allowed-registries: {s} (required by {s})",
                        .{ registry_url, req.name },
                    );
                    defer allocator.free(msg);
                    writer.emit(.{ .err = msg });
                    return error.RegistryNotAllowed;
                }
            }

            const npm_alias = parseNpmAlias(effective_range);
            try pending_batch.append(.{
                .name = req.name,
                .eff_range = effective_range,
                .optional = req.optional,
                .real_name = if (npm_alias) |a| try allocator.dupe(u8, a.real_name) else null,
                .real_range = if (npm_alias) |a| try allocator.dupe(u8, a.real_range) else null,
            });
        }

        if (pending_batch.items.len == 0) break;

        // --- Dispatch the wave's registry requests in chunks ---
        //
        // Each chunk is one curl --parallel invocation.  Processing results
        // after each chunk (rather than after the whole wave) keeps the
        // progress bar updating incrementally so the install never appears
        // frozen.  Chunk size = opts.concurrency (default 32) - small enough
        // to avoid overwhelming private registries and large enough that the
        // per-spawn overhead stays negligible.

        const chunk_size: usize = @intCast(opts.concurrency);
        var chunk_start: usize = 0;

        while (chunk_start < pending_batch.items.len) {
            const chunk_end = @min(chunk_start + chunk_size, pending_batch.items.len);
            const chunk = pending_batch.items[chunk_start..chunk_end];
            chunk_start = chunk_end;

            const batch_items = try allocator.alloc(registry_client.BatchItem, chunk.len);
            defer allocator.free(batch_items);
            for (chunk, batch_items) |pf, *bi| {
                // For npm aliases (e.g. "react-is-18": "npm:react-is@^18.3.1"), the
                // registry request must use the real package name ("react-is"), not the
                // alias ("react-is-18") which does not exist on the registry.
                bi.* = .{ .name = pf.real_name orelse pf.name, .optional = pf.optional };
            }

            const batch_results = try registry_client.fetchMetadataBatch(allocator, batch_items, config);
            defer {
                for (batch_results) |*r| {
                    if (r.meta) |*m| m.deinit(allocator);
                    if (r.err_msg) |m| allocator.free(m);
                }
                allocator.free(batch_results);
            }

            for (batch_results, chunk) |*result, pf| {
                if (result.err) |err| {
                    if (pf.optional) continue;
                    // Use the per-result error message (set during batch processing).
                    // This avoids cross-contamination: before this fix, a shared global
                    // buffer was overwritten by each failing item, causing item[0] to
                    // display item[N-1]'s URL in its error message.
                    if (result.err_msg) |reg_msg| {
                        const msg = std.fmt.allocPrint(
                            allocator,
                            "failed to fetch metadata for {s}: {s} ({s})",
                            .{ pf.name, reg_msg, @errorName(err) },
                        ) catch pf.name;
                        defer if (msg.ptr != pf.name.ptr) allocator.free(msg);
                        writer.emit(.{ .err = msg });
                    } else {
                        const msg = std.fmt.allocPrint(
                            allocator,
                            "failed to fetch metadata for {s}: {s}",
                            .{ pf.name, @errorName(err) },
                        ) catch pf.name;
                        defer if (msg.ptr != pf.name.ptr) allocator.free(msg);
                        writer.emit(.{ .err = msg });
                    }
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

                // Security: minimum package age filter.
                // Remove versions that were published too recently.
                // Skipped for own workspace packages (auto_link_patterns or
                // any workspace package in this repo).
                if (config.minimum_package_age_seconds > 0 and
                    !config.isExemptFromSecurity(pf.name) and
                    !workspace_names.contains(pf.name))
                {
                    const now_secs = std.time.timestamp();
                    const min_age: i64 = @intCast(config.minimum_package_age_seconds);
                    const cutoff = now_secs - min_age;
                    var i: usize = 0;
                    while (i < version_strs.items.len) {
                        const ver = version_strs.items[i];
                        const vi = meta.versions.get(ver) orelse {
                            i += 1;
                            continue;
                        };
                        // published_at == 0 means no timing info; allow it to be
                        // conservative (don't block packages with no timestamp).
                        if (vi.published_at > 0 and vi.published_at > cutoff) {
                            _ = version_strs.swapRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                }

                const latest = meta.dist_tags.get("latest");
                // For npm aliases (e.g. "react-is-18": "npm:react-is@^18.3.1"), use the
                // real semver range extracted from the npm: prefix, not the full alias range.
                const semver_range = pf.real_range orelse pf.eff_range;
                const best_ver = semver.maxSatisfying(
                    allocator,
                    version_strs.items,
                    semver_range,
                    latest,
                ) orelse {
                    if (pf.optional) continue;
                    // Check if there IS a satisfying version but it was too new.
                    if (config.minimum_package_age_seconds > 0) {
                        var all_strs = try std.ArrayList([]const u8).initCapacity(allocator, meta.versions.count());
                        defer all_strs.deinit();
                        var all_it = meta.versions.keyIterator();
                        while (all_it.next()) |k| try all_strs.append(k.*);
                        if (semver.maxSatisfying(allocator, all_strs.items, semver_range, latest) != null) {
                            const msg = try std.fmt.allocPrint(
                                allocator,
                                "security: all versions of {s} satisfying \"{s}\" were published within the last {d}s",
                                .{ pf.name, semver_range, config.minimum_package_age_seconds },
                            );
                            defer allocator.free(msg);
                            writer.emit(.{ .err = msg });
                            return error.PackageTooNew;
                        }
                    }
                    const warn_msg = try std.fmt.allocPrint(
                        allocator,
                        "no version of {s} satisfies range \"{s}\"",
                        .{ pf.name, semver_range },
                    );
                    defer allocator.free(warn_msg);
                    writer.emit(.{ .warning = warn_msg });
                    return error.NoMatchingVersion;
                };

                const ver_info = meta.versions.get(best_ver).?;

                const key = try std.fmt.allocPrint(
                    allocator,
                    "{s}@{s}",
                    .{ pf.name, ver_info.version },
                );

                // Record range → resolved key for lockfile pattern generation.
                {
                    const rtk_pat = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ pf.name, pf.eff_range });
                    const rtk_val = try allocator.dupe(u8, key);
                    const gop = try range_to_key.getOrPut(allocator, rtk_pat);
                    if (gop.found_existing) {
                        allocator.free(rtk_pat);
                        allocator.free(gop.value_ptr.*);
                    }
                    gop.value_ptr.* = rtk_val;
                }

                if (resolved_set.contains(key)) {
                    allocator.free(key);
                    try enqueueMapDeps(allocator, &queue, &ver_info.dependencies, false);
                    try enqueueMapDeps(allocator, &queue, &ver_info.optional_dependencies, opts.ignore_optional);
                    continue;
                }

                const rp = ResolvedPackage{
                    .name = try allocator.dupe(u8, pf.name),
                    .version = try allocator.dupe(u8, ver_info.version),
                    .tarball_url = try allocator.dupe(u8, ver_info.tarball),
                    .integrity = try allocator.dupe(u8, ver_info.integrity),
                    // For npm aliases, the registry scope comes from the real package
                    // name, not the alias (e.g. "@myorg/util" in "npm:@myorg/util@^1").
                    .registry = try allocator.dupe(u8, config.getRegistry(extractScope(pf.real_name orelse pf.name))),
                    .is_workspace = false,
                    .is_git = false,
                    .dependencies = try copyStringMap(allocator, &ver_info.dependencies),
                    .optional_dependencies = try copyStringMap(allocator, &ver_info.optional_dependencies),
                };
                try resolved_set.put(allocator, key, rp);

                try enqueueMapDeps(allocator, &queue, &ver_info.dependencies, false);
                try enqueueMapDeps(allocator, &queue, &ver_info.optional_dependencies, opts.ignore_optional);

                writer.emit(.{ .resolve_progress = .{
                    .resolved = @intCast(resolved_set.count()),
                    .total = @intCast(queue.items.len),
                    .name = rp.name,
                } });
            }
        }

        // Free npm alias strings duped during enqueueing before reusing the list.
        for (pending_batch.items) |pf| {
            if (pf.real_name) |rn| allocator.free(rn);
            if (pf.real_range) |rr| allocator.free(rr);
        }
        pending_batch.clearRetainingCapacity();
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

    const new_lock = try buildLockfile(allocator, &resolved_set, &range_to_key);

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

/// A registry package queued for batch fetching in the current BFS wave.
const PendingFetch = struct {
    /// Package name as declared by the depending package (alias or real name).
    /// Used as the node_modules directory name and in user-facing error messages.
    name: []const u8,
    eff_range: []const u8,
    optional: bool,
    /// For npm aliases (range starts with "npm:"): the real registry package name.
    /// e.g. for `"react-is-18": "npm:react-is@^18.3.1"`, this is "react-is".
    real_name: ?[]const u8 = null,
    /// For npm aliases: the real semver range extracted from the npm: prefix.
    /// e.g. for "npm:react-is@^18.3.1", this is "^18.3.1".
    real_range: ?[]const u8 = null,
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
    // A lockfile entry is a git dep when its resolved URL starts with a known
    // git scheme (the same check used during fresh resolution).
    const git = isGitDep(entry.resolved) or isGitDep(entry.version);
    return ResolvedPackage{
        .name = try allocator.dupe(u8, name),
        .version = try allocator.dupe(u8, entry.version),
        // For git deps the resolved field holds the original git URL (with any
        // branch/subdir fragment).  Fall back to the version string so that
        // packages written by older nayr versions (resolved="") still work.
        .tarball_url = try allocator.dupe(u8, if (git and entry.resolved.len == 0) entry.version else entry.resolved),
        .integrity = try allocator.dupe(u8, entry.integrity),
        .registry = try allocator.dupe(u8, config.getRegistry(extractScope(name))),
        .is_workspace = false,
        .is_git = git,
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
    const parts = parseGitDepUrl(url);

    const org_repo = extractGitOrgRepo(url);
    const should_pin = config.shouldPinGitHash(org_repo[0], org_repo[1]);

    // Optionally pin the commit hash with `git ls-remote`.
    var head_hash: []const u8 = "";
    if (should_pin) {
        head_hash = resolveGitHash(allocator, url) catch "";
    }
    defer if (head_hash.len > 0) allocator.free(head_hash);

    // Version stored in the lockfile:
    //   pinned  → "<clean_url>#<commit_hash>"   (branch/subdir preserved in tarball_url)
    //   unpinned → the original URL as-is (re-resolved on next install)
    //
    // We deliberately keep the commit hash in a separate segment so that the
    // lockfile key stays unambiguous even when the URL contains a #fragment.
    const version = if (head_hash.len > 0)
        try std.fmt.allocPrint(allocator, "{s}#{s}", .{ parts.clean_url, head_hash })
    else
        try allocator.dupe(u8, url);

    return ResolvedPackage{
        .name = try allocator.dupe(u8, name),
        .version = version,
        // tarball_url carries the full original URL (including branch/subdir
        // fragment) so the linker can parse it with parseGitDepUrl.
        .tarball_url = try allocator.dupe(u8, url),
        .integrity = "",
        .registry = "",
        .is_workspace = false,
        .is_git = true,
        .dependencies = .{},
        .optional_dependencies = .{},
    };
}

/// Parsed components of a git dependency URL.
///
/// Supported format:  `git+<scheme>://<host>/<path>[#<branch>[:<subdir>]]`
///
/// Examples:
///   git+https://github.com/org/repo               → branch=null, subdir=null
///   git+https://github.com/org/repo#main          → branch="main", subdir=null
///   git+https://github.com/org/repo#main:pkg/core → branch="main", subdir="pkg/core"
///   git+https://github.com/org/repo#:pkg/core     → branch=null,   subdir="pkg/core"
pub const GitDepParts = struct {
    /// Clone URL (no `git+` prefix, no `#fragment`).
    clean_url: []const u8,
    /// Branch / tag / ref to checkout. Null means use the remote default (HEAD).
    branch: ?[]const u8,
    /// Subdirectory within the repo to use as the package root. Null = root.
    subdir: ?[]const u8,
};

/// Parses a git dependency URL into its component parts.
/// All returned slices are sub-slices of `url` (no allocation).
pub fn parseGitDepUrl(url: []const u8) GitDepParts {
    const no_prefix = if (std.mem.startsWith(u8, url, "git+")) url[4..] else url;

    const hash_pos = std.mem.indexOfScalar(u8, no_prefix, '#') orelse {
        return .{ .clean_url = no_prefix, .branch = null, .subdir = null };
    };

    const clean_url = no_prefix[0..hash_pos];
    const fragment = no_prefix[hash_pos + 1 ..];

    if (std.mem.indexOfScalar(u8, fragment, ':')) |cp| {
        const branch_part = fragment[0..cp];
        const path_part = fragment[cp + 1 ..];
        return .{
            .clean_url = clean_url,
            .branch = if (branch_part.len > 0) branch_part else null,
            .subdir = if (path_part.len > 0) path_part else null,
        };
    }

    return .{
        .clean_url = clean_url,
        .branch = if (fragment.len > 0) fragment else null,
        .subdir = null,
    };
}

/// Runs `git ls-remote` and returns the commit hash for the given ref.
/// When `branch` is null, queries `HEAD`; otherwise `refs/heads/<branch>`.
fn resolveGitHash(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const parts = parseGitDepUrl(url);

    const ref: []const u8 = if (parts.branch) |b| blk: {
        break :blk try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{b});
    } else "HEAD";
    defer if (parts.branch != null) allocator.free(ref);

    var child = std.process.Child.init(
        &[_][]const u8{ "git", "ls-remote", parts.clean_url, ref },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        if (err == error.FileNotFound) IoTrace.recordMissingPath("git (not found in PATH)");
        return err;
    };

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 256);
    defer allocator.free(stdout);
    _ = try child.wait();

    // Output format: "<hash>\t<ref>\n"
    const tab = std.mem.indexOfScalar(u8, stdout, '\t') orelse return error.GitHashNotFound;
    return allocator.dupe(u8, stdout[0..tab]);
}

/// Extracts (org, repo) from a GitHub URL.
///
/// Returns `("", "")` for non-GitHub URLs.
fn extractGitOrgRepo(url: []const u8) [2][]const u8 {
    // github.com/org/repo or https://github.com/org/repo
    const gh_prefix = "github.com/";
    const start = std.mem.indexOf(u8, url, gh_prefix) orelse return .{ "", "" };
    const rest = url[start + gh_prefix.len ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .{ rest, "" };
    return .{ rest[0..slash], rest[slash + 1 ..] };
}

fn extractScope(name: []const u8) ?[]const u8 {
    if (name.len == 0 or name[0] != '@') return null;
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return null;
    return name[0..slash];
}

/// Parsed result of an npm alias range like `npm:react-is@^18.3.1`.
const NpmAlias = struct {
    /// The real package name to fetch from the registry (e.g. "react-is").
    real_name: []const u8,
    /// The actual semver range (e.g. "^18.3.1").
    real_range: []const u8,
};

/// Parses an npm alias range of the form `npm:<package>@<range>`.
///
/// Returns null for ranges that do not start with `npm:`.
/// Handles scoped packages (e.g. `npm:@babel/core@^7.0.0`).
///
/// @param range - The raw version range string from a dependency map.
/// @returns Parsed alias with real_name and real_range, or null if not an alias.
fn parseNpmAlias(range: []const u8) ?NpmAlias {
    const prefix = "npm:";
    if (!std.mem.startsWith(u8, range, prefix)) return null;
    const rest = range[prefix.len..]; // e.g. "react-is@^18.3.1" or "@babel/core@^7.0.0"

    // Find the last `@` to split name from version range.
    // For scoped packages like `@babel/core@^7`, the first `@` is part of the name.
    const at = std.mem.lastIndexOfScalar(u8, rest, '@') orelse return null;
    if (at == 0) return null; // bare "@" with no name
    return NpmAlias{
        .real_name = rest[0..at],
        .real_range = rest[at + 1 ..],
    };
}

fn buildLockfile(
    allocator: std.mem.Allocator,
    packages: *const std.StringHashMapUnmanaged(ResolvedPackage),
    range_to_key: *const std.StringHashMapUnmanaged([]const u8),
) !Lockfile {
    // Group range patterns (e.g. "lodash@^4.17.0") by their resolved key
    // (e.g. "lodash@4.17.21") so that each lockfile entry stores all the
    // request ranges that map to that resolved version.  This makes the
    // resolver's lockfile lookup (which uses "name@range" as the key) work
    // on subsequent installs, avoiding full registry re-fetches.
    var key_to_patterns = std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)){};
    defer {
        var ktp_it = key_to_patterns.iterator();
        while (ktp_it.next()) |kv| {
            for (kv.value_ptr.items) |s| allocator.free(s);
            kv.value_ptr.deinit(allocator);
        }
        key_to_patterns.deinit(allocator);
    }
    {
        var rtk_it = range_to_key.iterator();
        while (rtk_it.next()) |kv| {
            const gop = try key_to_patterns.getOrPut(allocator, kv.value_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.append(allocator, try allocator.dupe(u8, kv.key_ptr.*));
        }
    }

    var entries = std.ArrayList(lockfile_types.LockfileEntry).init(allocator);
    var pattern_map = std.StringHashMapUnmanaged(usize){};

    var it = packages.iterator();
    while (it.next()) |kv| {
        const pkg = kv.value_ptr;
        const pkg_key = kv.key_ptr.*; // "name@version"

        // Build patterns list: start with the canonical "name@version" pattern,
        // then append all collected request-range patterns.
        var patterns_list = std.ArrayList([]const u8).init(allocator);
        defer patterns_list.deinit();
        try patterns_list.append(try std.fmt.allocPrint(allocator, "{s}@{s}", .{ pkg.name, pkg.version }));

        if (key_to_patterns.get(pkg_key)) |range_pats| {
            for (range_pats.items) |pat| {
                const already = for (patterns_list.items) |p| {
                    if (std.mem.eql(u8, p, pat)) break true;
                } else false;
                if (!already) try patterns_list.append(try allocator.dupe(u8, pat));
            }
        }

        const patterns = try patterns_list.toOwnedSlice();

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
        for (patterns) |pat| try pattern_map.put(allocator, pat, idx);
        try entries.append(entry);
    }

    return Lockfile{
        .pattern_map = pattern_map,
        .entries = try entries.toOwnedSlice(),
        .workspaces = .{},
    };
}
