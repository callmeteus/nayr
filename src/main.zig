//! nayr - a fast, lock-free package manager for the Node.js ecosystem.
//!
//! nayr is a drop-in replacement for Yarn Classic v1, written in Zig for
//! maximum performance. It supports:
//!   - Workspaces with hoisting and nohoist
//!   - A global cache with atomic, lock-free writes
//!   - Native linking (replaces the `nayr` npm package)
//!   - Registry auto-discovery (replaces `verc`)
//!   - Multi-registry login
//!   - TUI output with --format=tui|text|json
//!
//! Usage: nayr [command] [options]

const std = @import("std");
const cli = @import("cli/root.zig");
const output = @import("util/output.zig");
const IoTrace = @import("util/io_trace.zig").IoTrace;

pub fn main() !void {
    // Use a GeneralPurposeAllocator for the CLI lifetime. Each sub-phase
    // (resolve, fetch, link) will create its own arena on top of this.
    // thread_safe = true is required because the fetch and resolve phases
    // spawn thread pools that allocate/free on this same allocator concurrently
    // (fetchWorker via parent_alloc, cache.store via self.allocator, and the
    // resolver's metadata batch workers). Without the mutex, concurrent access
    // to the GPA's internal freelists silently corrupts them, manifesting as
    // ever-growing RSS (allocations are "lost" and never returned to the OS).
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Collect raw args.
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Dispatch to the CLI router.
    cli.run(allocator, args) catch |err| {
        const stderr = std.io.getStdErr().writer();
        const colour = output.hasTtyStderr();
        const red_bold = if (colour) "\x1b[1;31m" else "";
        const reset = if (colour) "\x1b[0m" else "";

        if (err == error.FileNotFound) {
            if (IoTrace.takeMissingPath()) |p| {
                stderr.print("{s}error{s} File not found: {s}\n", .{ red_bold, reset, p }) catch {};
            } else {
                printFileNotFoundWithoutPath(stderr, allocator, red_bold, reset);
            }
            std.process.exit(1);
        }

        const msg = switch (err) {
            error.NotYarnV1Lockfile => "yarn.lock found but it is not a Yarn v1 lockfile (Yarn Berry / PnP is not supported).",
            error.FrozenLockfileChanged => "Lockfile would need to be updated but frozen mode is on. Omit --frozen-lockfile, pass --no-frozen-lockfile, or fix the lockfile.",
            error.NetworkError => "Network request failed. Check your internet connection and registry URL.\n       (hint: run with --verbose for more details)",
            error.HttpError => "Registry returned an HTTP error. Common causes: wrong registry URL, missing auth token, or package does not exist.",
            error.RegistryError => null, // detailed message already emitted by the resolver; fall through to errorName
            error.MissingName, error.InvalidMetadata => "Registry returned an unexpected or malformed response for a package.\n       The package may not exist, the registry URL may be wrong, or auth may be required.",
            error.NoMatchingVersion => "No version of a required package satisfies the requested range - see the warning above.",
            error.GitHostNotAllowed => "A git dependency was blocked by the allowed-git-hosts policy in your .nayrrc.",
            error.RegistryNotAllowed => "A package registry was blocked by the allowed-registries policy in your .nayrrc.",
            error.PackageTooNew => "A package version was blocked by the minimum-package-age policy in your .nayrrc.",
            error.OutOfMemory => "Out of memory.",
            error.AccessDenied => "Permission denied. Check file/directory permissions.",
            error.InvalidCharacter, error.UnexpectedEndOfInput => "package.json contains invalid JSON. Fix the syntax and try again.",
            else => null,
        };
        if (msg) |m| {
            stderr.print("{s}error{s} {s}\n", .{ red_bold, reset, m }) catch {};
        } else if (err == error.RegistryError) {
            // The resolver already printed the per-package error line; no extra noise.
        } else {
            stderr.print("{s}error{s} {s}\n", .{ red_bold, reset, @errorName(err) }) catch {};
        }
        std.process.exit(1);
    };
}

/// Prints a `FileNotFound` hint when no path was recorded (e.g. spawn ENOENT).
///
/// ## Parameters
/// - `stderr` - Stderr writer.
/// - `allocator` - Allocator for temporary path strings.
/// - `red_bold` - ANSI prefix for errors (or empty).
/// - `reset` - ANSI reset (or empty).
///
/// ## Returns
/// Nothing.
fn printFileNotFoundWithoutPath(
    stderr: anytype,
    allocator: std.mem.Allocator,
    red_bold: []const u8,
    reset: []const u8,
) void {
    const cwd_opt = std.process.getCwdAlloc(allocator) catch null;
    defer if (cwd_opt) |c| allocator.free(c);
    if (cwd_opt) |cwd| {
        const pj = std.fs.path.join(allocator, &.{ cwd, "package.json" }) catch {
            stderr.print("{s}error{s} File not found (path not recorded). cwd={s}. Pass --cwd <project root>.\n", .{ red_bold, reset, cwd }) catch {};
            return;
        };
        defer allocator.free(pj);
        const pj_status: []const u8 = if (std.fs.accessAbsolute(pj, .{})) |_| "present" else |_| "missing";
        stderr.print(
            "{s}error{s} File not found (path not recorded). cwd={s}; package.json at {s}: {s}. Try `nayr --cwd <repo>` or fix Docker WORKDIR/COPY.\n",
            .{ red_bold, reset, cwd, pj, pj_status },
        ) catch {};
        return;
    }
    stderr.print("{s}error{s} File not found (path not recorded). Could not read cwd. Pass --cwd <project root>.\n", .{ red_bold, reset }) catch {};
}
