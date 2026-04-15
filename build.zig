//! nayr build script.
//!
//! Builds the nayr binary for the current host or cross-compiles for
//! any supported target. Supports three output modes:
//!   zig build           — debug binary
//!   zig build -Doptimize=ReleaseFast  — optimized binary
//!   zig build test      — run all tests
//!   zig build docs      — generate HTML documentation

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Allow the user to choose the optimization level (default: Debug).
    const optimize = b.standardOptimizeOption(.{});

    // Allow the user to choose the target triple (default: native host).
    const target = b.standardTargetOptions(.{});

    // -------------------------------------------------------------------------
    // Main executable
    // -------------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "nayr",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // The test runner root is `tests.zig` at the workspace root, so all
    // test sub-files may use `@import("src/...")` relative to the workspace.
    const unit_tests = b.addTest(.{
        .name = "nayr_tests",
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // -------------------------------------------------------------------------
    // Cross-compilation targets
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
