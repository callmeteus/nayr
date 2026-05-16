//! nayr build script.
//!
//! Builds the nayr binary for the current host or cross-compiles for
//! any supported target. Supports three output modes:
//!   zig build                        - debug binary
//!   zig build -Doptimize=ReleaseFast - optimized binary
//!   zig build test                   - run all tests
//!   zig build lint                   - zig fmt --check + zlint (needs zlint)
//!   zig build cross                  - cross-compile for all targets

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // -------------------------------------------------------------------------
    // Build options - version embedded from package.json at build time
    // -------------------------------------------------------------------------
    const version = readPackageVersion(b) catch "0.0.0";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // -------------------------------------------------------------------------
    // Main executable
    // -------------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "nayr",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    // -------------------------------------------------------------------------
    // Run step: `zig build run -- <args>`
    // -------------------------------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run nayr");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------------
    // Test step: `zig build test`
    // -------------------------------------------------------------------------
    const test_step = b.step("test", "Run all unit tests");

    const unit_tests = b.addTest(.{
        .name = "nayr_tests",
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addOptions("build_options", options);
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // -------------------------------------------------------------------------
    // Lint: `zig build lint` (delegates to scripts/lint.sh)
    // -------------------------------------------------------------------------
    const lint_step = b.step("lint", "Run zig fmt --check and zlint");
    const lint_cmd = b.addSystemCommand(&.{ "sh", "scripts/lint.sh" });
    lint_cmd.setCwd(b.path("."));
    lint_step.dependOn(&lint_cmd.step);

    // -------------------------------------------------------------------------
    // Cross-compilation targets: `zig build cross`
    // -------------------------------------------------------------------------
    const cross_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    };

    const cross_step = b.step("cross", "Cross-compile for all supported targets");

    for (cross_targets) |cross_target| {
        const resolved = b.resolveTargetQuery(cross_target);
        const cross_exe = b.addExecutable(.{
            .name = "nayr",
            .root_source_file = b.path("src/main.zig"),
            .target = resolved,
            .optimize = .ReleaseFast,
        });
        cross_exe.root_module.addOptions("build_options", options);
        const install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = b.fmt("bin/{s}-{s}", .{
                        @tagName(cross_target.cpu_arch.?),
                        @tagName(cross_target.os_tag.?),
                    }),
                },
            },
        });
        cross_step.dependOn(&install.step);
    }
}

// ============================================================================
// Helpers
// ============================================================================

/// Reads the "version" field from package.json at build time.
/// Returns a duplicated string owned by the build allocator, or an error.
fn readPackageVersion(b: *std.Build) ![]const u8 {
    const content = try b.build_root.handle.readFileAlloc(b.allocator, "package.json", 16 * 1024);
    defer b.allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, b.allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get("version")) |v| {
            if (v == .string) return b.dupe(v.string);
        }
    }
    return error.VersionNotFound;
}
