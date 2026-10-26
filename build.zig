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

    const zigbox = b.dependency("zigbox", .{ .target = target, .optimize = optimize });
    const zigbox_module = zigbox.module("zigbox");

    add_executables(b, .{
        .target = target,
        .optimize = optimize,
        .options = options,
        .zigbox = zigbox_module,
    });

    // SQLite's C header, translated (`@cImport` is gone). Backends import it as `sqlite_c`.
    const sqlite = b.addTranslateC(.{
        .root_source_file = b.path("src/sqlite_c.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();
    sqlite.linkSystemLibrary("sqlite3", .{});

    // libpq's C header, translated the same way. The header lives under /usr/include/postgresql on
    // Debian and Ubuntu (libpq-dev); `-Dpq-include=` names another directory.
    const pq_include = b.option([]const u8, "pq-include", "Directory of libpq-fe.h") orelse
        "/usr/include/postgresql";
    const libpq = b.addTranslateC(.{
        .root_source_file = b.path("src/libpq_c.h"),
        .target = target,
        .optimize = optimize,
    });
    libpq.addIncludePath(.{ .cwd_relative = pq_include });
    const libpq_module = libpq.createModule();
    libpq_module.linkSystemLibrary("pq", .{});

    const test_step = b.step("test", "Run unit and snapshot tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "sqlite_c", .module = sqlite },
                .{ .name = "libpq_c", .module = libpq_module },
                .{ .name = "zigbox", .module = zigbox_module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    add_store_step(b, .{
        .target = target,
        .optimize = optimize,
        .sqlite = sqlite,
        .libpq = libpq_module,
        .zigbox = zigbox_module,
    });
    add_tidy_step(b);
    add_pg_dev_steps(b);
}

const ExecutablesOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    zigbox: *std.Build.Module,
};

fn add_executables(b: *std.Build, executables_options: ExecutablesOptions) void {
    const build_options = executables_options.options.createModule();
    for (executables) |executable| {
        const exe = b.addExecutable(.{
            .name = executable.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(executable.root),
                .target = executables_options.target,
                .optimize = executables_options.optimize,
                .imports = &.{
                    .{ .name = "build_options", .module = build_options },
                    .{ .name = "zigbox", .module = executables_options.zigbox },
                },
            }),
        });
        b.installArtifact(exe);
    }
}

/// `zig build pg-up` starts a throwaway Postgres for the conformance suite; `pg-down` removes it.
fn add_pg_dev_steps(b: *std.Build) void {
    const tool = b.addExecutable(.{
        .name = "pg_dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pg_dev.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const commands = [_][]const u8{ "up", "down" };
    const descriptions = [_][]const u8{
        "Start a throwaway Postgres for test-store (prints its ZCUBE_TEST_POSTGRES)",
        "Stop the throwaway Postgres and delete its files",
    };
    for (commands, descriptions) |command, description| {
        const run = b.addRunArtifact(tool);
        run.addArg(command);
        run.has_side_effects = true;
        const step_name = b.fmt("pg-{s}", .{command});
        b.step(step_name, description).dependOn(&run.step);
    }
}

const StoreStepOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sqlite: *std.Build.Module,
    libpq: *std.Build.Module,
    zigbox: *std.Build.Module,
};

/// The database `-Dbackend=postgres` runs against: `-Dpostgres=<libpq settings>`, else the
/// `ZCUBE_TEST_POSTGRES` environment variable, else the server `zig build pg-up` starts.
fn postgres_conninfo(b: *std.Build) []const u8 {
    const option = b.option([]const u8, "postgres", "libpq settings of the test database");
    if (option) |settings| return settings;
    if (b.graph.environ_map.get("ZCUBE_TEST_POSTGRES")) |settings| return settings;
    return "host=127.0.0.1 port=55432 user=zcube dbname=postgres";
}

/// `zig build test-store -Dbackend=memory|sqlite|postgres [-Dseed=N]`: the conformance suite, one
/// test binary written against the `Store` interface, run against the chosen backend. The
/// backend's own tests come with it (they are in the same compilation), so for Postgres the
/// binary needs the database even for those.
fn add_store_step(b: *std.Build, step_options: StoreStepOptions) void {
    const backend = b.option(Backend, "backend", "Store backend for test-store") orelse .memory;
    const seed = b.option(u64, "seed", "Seed for the randomised store tests (default: random)");
    const step = b.step("test-store", "Run the store conformance suite (-Dbackend=...)");
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
                .{ .name = "libpq_c", .module = step_options.libpq },
                .{ .name = "zigbox", .module = step_options.zigbox },
            },
        }),
    });
    const run = b.addRunArtifact(tests);
    // A passing run is not cached: the build runner draws a new seed per invocation (it is not
    // part of the cache key), so every run counts.
    run.has_side_effects = true;
    if (backend == .postgres) {
        const conninfo = postgres_conninfo(b);
        run.setEnvironmentVariable("ZCUBE_TEST_POSTGRES", conninfo);
        run.setEnvironmentVariable("ZCUBE_TEST_POSTGRES_REQUIRED", "1");
    }
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
