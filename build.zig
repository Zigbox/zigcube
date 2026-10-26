const std = @import("std");

const executables = [_]struct { name: []const u8, root: []const u8 }{
    .{ .name = "zcube", .root = "src/zcube.zig" },
    .{ .name = "zcube-server", .root = "src/zcube_server.zig" },
    .{ .name = "zcube-agent", .root = "src/zcube_agent.zig" },
};

const Backend = enum { memory, sqlite, postgres };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The version has one source of truth, build.zig.zon, handed to the code as an option.
    const manifest = @import("build.zig.zon");
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    for (executables) |executable| {
        const exe = b.addExecutable(.{
            .name = executable.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(executable.root),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "build_options", .module = options.createModule() }},
            }),
        });
        b.installArtifact(exe);
    }

    // SQLite's C header, translated (`@cImport` is gone). Backends import it as `sqlite_c`.
    const sqlite = b.addTranslateC(.{
        .root_source_file = b.path("src/sqlite_c.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();
    sqlite.linkSystemLibrary("sqlite3", .{});

    const test_step = b.step("test", "Run unit and snapshot tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "sqlite_c", .module = sqlite },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    add_store_step(b, .{ .target = target, .optimize = optimize, .sqlite = sqlite });
    add_tidy_step(b);
}

const StoreStepOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sqlite: *std.Build.Module,
};

/// `zig build test-store -Dbackend=memory|sqlite [-Dseed=N]`: the conformance suite, one test
/// binary written against the `Store` interface, run against the chosen backend.
fn add_store_step(b: *std.Build, step_options: StoreStepOptions) void {
    const backend = b.option(Backend, "backend", "Store backend for test-store") orelse .memory;
    const seed = b.option(u64, "seed", "Seed for the randomised store tests (default: random)");
    const step = b.step("test-store", "Run the store conformance suite (-Dbackend=...)");
    if (backend == .postgres) {
        step.dependOn(&b.addFail("the postgres store backend arrives in C0 slice 3").step);
        return;
    }
    const options = b.addOptions();
    options.addOption(Backend, "backend", backend);
    options.addOption(?u64, "seed", seed);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/store_conformance.zig"),
            .target = step_options.target,
            .optimize = step_options.optimize,
            .imports = &.{
                .{ .name = "conformance_options", .module = options.createModule() },
                .{ .name = "sqlite_c", .module = step_options.sqlite },
            },
        }),
    });
    const run = b.addRunArtifact(tests);
    // A passing run is not cached: the build runner draws a new seed per invocation (it is not
    // part of the cache key), so every run counts.
    run.has_side_effects = true;
    step.dependOn(&run.step);
}

fn add_tidy_step(b: *std.Build) void {
    // Tidy is a host tool: always built for the machine running the build.
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tidy.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(tidy);
    run.setCwd(b.path("."));
    // Formatting is checked alongside the mechanical rules: both must pass before review.
    const format = b.addFmt(.{ .paths = &.{ b.path("src"), b.path("build.zig") }, .check = true });
    const step = b.step("tidy", "Check formatting, line and function length, banned patterns");
    step.dependOn(&format.step);
    step.dependOn(&run.step);
}
