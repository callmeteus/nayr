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
        const stderr = std.io.getStdErr().writer();
        const msg = switch (err) {
            error.NotYarnV1Lockfile => "yarn.lock found but it is not a Yarn v1 lockfile (Yarn Berry / PnP is not supported).",
            error.FileNotFound => "No package.json found in the current directory. Run nayr inside a Node.js project.",
            error.FrozenLockfileChanged => "--frozen-lockfile is set but the lockfile would need to be updated.",
            error.NetworkError => "Network request failed. Check your internet connection and registry URL.\n       (hint: run with --verbose for more details)",
            error.HttpError => "Registry returned an HTTP error. Common causes: wrong registry URL, missing auth token, or package does not exist.",
            error.RegistryError => "Registry returned an error response - see the message above for details.",
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
        const colour = output.hasTtyStderr();
        const red_bold = if (colour) "\x1b[1;31m" else "";
        const reset = if (colour) "\x1b[0m" else "";
        if (msg) |m| {
            stderr.print("{s}error{s} {s}\n", .{ red_bold, reset, m }) catch {};
        } else {
            stderr.print("{s}error{s} {s}\n", .{ red_bold, reset, @errorName(err) }) catch {};
        }
        std.process.exit(1);
    };
}
