//! nayr — a fast, lock-free package manager for the Node.js ecosystem.
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

pub fn main() !void {
    // Use a GeneralPurposeAllocator for the CLI lifetime. Each sub-phase
    // (resolve, fetch, link) will create its own arena on top of this.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Collect raw args.
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Dispatch to the CLI router.
    cli.run(allocator, args) catch |err| {
        // Top-level error handler: print to stderr and exit with code 1.
        const stderr = std.io.getStdErr().writer();
        stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
}
