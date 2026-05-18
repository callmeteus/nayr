//! Package Fetcher
//!
//! Downloads package tarballs from npm registries in parallel using a thread
//! pool, then stores them in the global cache. Each thread has its own HTTP
//! connection pool - zero shared state between threads.
//!
//! Fetch pipeline for each package:
//!   1. Check cache (`cache.has(name, version)`). Hit → skip download.
//!   2. Download tarball from registry to a temp file.
//!   3. Verify integrity (sha512 inline during download).
//!   4. Atomically rename temp → cache dir.
//!
//! Progress is reported via the `output.Writer` event system.

const std = @import("std");
const cache_mod = @import("cache.zig");
const resolver_mod = @import("resolver.zig");
const registry_client = @import("../registry/client.zig");
const config_types = @import("../config/types.zig");
const output = @import("../util/output.zig");
const ResolvedPackage = resolver_mod.ResolvedPackage;
const Cache = cache_mod.Cache;
const Config = config_types.Config;

// ============================================================================
// Fetcher options
// ============================================================================

/// Controls the fetcher's parallelism and behaviour.
pub const FetcherOptions = struct {
    /// Number of concurrent download threads.
    concurrency: u32 = 8,
};

// ============================================================================
// Public API
// ============================================================================

/// Downloads all packages that are not already in cache.
///
/// Spawns up to `opts.concurrency` threads. Each thread takes work items
/// from an atomic ring buffer - no mutex, no lock contention.
///
/// ## Parameters
/// - `allocator`: Main allocator (each thread creates its own arena on top).
/// - `packages`: The resolved package map from the resolver.
/// - `cache`: Global cache instance.
/// - `config`: Merged config (for registry auth tokens).
/// - `writer`: Output event sink.
/// - `opts`: Fetch options.
pub fn fetchAll(
    allocator: std.mem.Allocator,
    packages: *const std.StringHashMapUnmanaged(ResolvedPackage),
    cache: *Cache,
    config: *const Config,
    writer: output.Writer,
    opts: FetcherOptions,
) !void {
    // Build a list of packages that need downloading (cache misses).
    var pending = std.ArrayList(*const ResolvedPackage).init(allocator);
    defer pending.deinit();

    var it = packages.valueIterator();
    while (it.next()) |pkg| {
        if (pkg.is_workspace or pkg.is_git or pkg.tarball_url.len == 0) continue;
        const in_cache = try cache.has(pkg.registry, pkg.name, pkg.version);
        if (!in_cache) {
            try pending.append(pkg);
        } else {
            writer.emit(.{ .cache_hit = .{ .name = pkg.name, .version = pkg.version } });
        }
    }

    if (pending.items.len == 0) return;

    // Atomic counter: threads use CAS to grab the next work item.
    var next_idx = std.atomic.Value(u32).init(0);
    var done_count = std.atomic.Value(u32).init(0);
    const total: u32 = @intCast(pending.items.len);

    // Share the pending slice, cache, and config between threads (read-only).
    const shared = SharedFetchState{
        .pending = pending.items,
        .cache = cache,
        .config = config,
        .next_idx = &next_idx,
        .done_count = &done_count,
        .total = total,
        .writer = writer,
    };

    const n_threads = @min(opts.concurrency, total);
    const threads = try allocator.alloc(std.Thread, n_threads);
    defer allocator.free(threads);

    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, fetchWorker, .{ &shared, allocator });
    }
    for (threads) |t| t.join();
}

// ============================================================================
// Thread worker
// ============================================================================

const SharedFetchState = struct {
    pending: []*const ResolvedPackage,
    cache: *Cache,
    config: *const Config,
    next_idx: *std.atomic.Value(u32),
    done_count: *std.atomic.Value(u32),
    total: u32,
    writer: output.Writer,
};

/// Worker function executed by each fetch thread.
///
/// Threads compete for work items using a lock-free atomic counter. Each
/// thread creates its own arena allocator, reset after every package so that
/// tarball buffers (up to 64 MB each) are freed promptly instead of
/// accumulating for the lifetime of the thread.
fn fetchWorker(shared: *const SharedFetchState, parent_alloc: std.mem.Allocator) void {
    // Use page_allocator as the arena backing so that reset(.free_all) calls
    // munmap() and actually returns pages to the OS after every package.
    // With retain_capacity + GPA backing, each thread permanently holds the
    // largest tarball slab it ever saw (up to 64 MB), and with 32 threads
    // that easily OOMs a machine with < 2 GB RAM.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // The client uses parent_alloc so that its per-request defer-frees are
    // real frees, not arena no-ops.  RegistryClient holds no long-lived state.
    var client = registry_client.RegistryClient.init(parent_alloc, shared.config);
    defer client.deinit();

    while (true) {
        // Atomically claim the next work item.
        const idx = shared.next_idx.fetchAdd(1, .acquire);
        if (idx >= shared.pending.len) break;

        // Free all arena pages back to the OS before starting the next package.
        // Peak RSS per thread is bounded to roughly one tarball at a time
        // (~avg 2 MB, max 64 MB) instead of accumulating the high-water mark
        // of every tarball ever processed by this thread.
        _ = arena.reset(.free_all);
        const allocator = arena.allocator();

        const pkg = shared.pending[idx];

        // Use a per-package temp path to avoid race conditions between threads
        // all writing to the same fixed temp file.
        const tmp_path = std.fmt.allocPrint(allocator, "/tmp/nayr-dl-{d}.tmp", .{idx}) catch {
            shared.writer.emit(.{ .warning = "OutOfMemory" });
            _ = shared.done_count.fetchAdd(1, .release);
            continue;
        };
        defer allocator.free(tmp_path);

        client.downloadTarball(pkg.tarball_url, tmp_path, pkg.integrity) catch |err| {
            const detail: []const u8 = if (err == error.IntegrityMismatch)
                "tarball checksum does not match lockfile — run nayr install again to re-fetch"
            else
                @errorName(err);
            const wmsg = std.fmt.allocPrint(
                allocator,
                "failed to download {s}@{s}: {s}",
                .{ pkg.name, pkg.version, detail },
            ) catch null;
            if (wmsg) |m| {
                defer allocator.free(m);
                shared.writer.emit(.{ .warning = m });
            }
            _ = shared.done_count.fetchAdd(1, .release);
            continue;
        };

        // Read the downloaded tarball and store in cache, then clean up.
        if (std.fs.openFileAbsolute(tmp_path, .{})) |f| {
            defer f.close();
            defer std.fs.deleteFileAbsolute(tmp_path) catch {};
            if (f.readToEndAlloc(allocator, 64 * 1024 * 1024)) |data| {
                shared.cache.store(pkg.registry, pkg.name, pkg.version, data) catch |err| {
                    const wmsg = std.fmt.allocPrint(
                        allocator,
                        "failed to cache {s}@{s}: {s}",
                        .{ pkg.name, pkg.version, @errorName(err) },
                    ) catch null;
                    if (wmsg) |m| {
                        defer allocator.free(m);
                        shared.writer.emit(.{ .warning = m });
                    }
                };
            } else |_| {}
        } else |_| {}

        const done = shared.done_count.fetchAdd(1, .release) + 1;
        shared.writer.emit(.{
            .fetch_progress = .{
                .fetched = done,
                .total = shared.total,
                .bytes_per_sec = 0, // TODO: track bandwidth
            },
        });
    }
}
