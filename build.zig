const std = @import("std");

const executables = [_]struct { name: []const u8, root: []const u8 }{
    .{ .name = "zcube", .root = "src/zcube.zig" },
    .{ .name = "zcube-server", .root = "src/zcube_server.zig" },
    .{ .name = "zcube-agent", .root = "src/zcube_agent.zig" },
};

/// Every WebAssembly run goes through Node twice, once per V8 compiler. Node 22's V8 sometimes
/// crashes the host process (SIGSEGV, not a trap) when it mixes its two tiers on one module, so a
/// run pins one tier; both together run every test on both compilers. docs/wasm.md, "Node 22
/// crashes when V8 mixes its compiler tiers".
const v8_modes = [_][]const u8{ "--liftoff-only", "--no-liftoff" };

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

    const c_modules = add_c_modules(b, target, optimize);
    const sqlite = c_modules.sqlite;
    const libpq_module = c_modules.libpq;

    // The single-threaded half of the conformance suite runs in `zig build test` against the
    // memory store; `test-store` runs the whole suite against the backend it is given.
    const memory_suite = memory_suite_options(b);
    const test_step = b.step("test", "Run unit and snapshot tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "conformance_options", .module = memory_suite.createModule() },
                .{ .name = "sqlite_c", .module = sqlite },
                .{ .name = "libpq_c", .module = libpq_module },
                .{ .name = "zigbox", .module = zigbox_module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // `-Dseed=N` is one option for two steps (test-store and sim-c0), so it is declared once.
    const seed_help = "Seed for test-store (default: random) and sim-c0 (default: 1)";
    const seed = b.option(u64, "seed", seed_help);
    add_store_step(b, .{
        .seed = seed,
        .target = target,
        .optimize = optimize,
        .sqlite = sqlite,
        .libpq = libpq_module,
        .zigbox = zigbox_module,
    });
    add_tidy_step(b);
    add_pg_dev_steps(b);
    const library = add_wasm_steps(b, optimize);
    add_console_steps(b);
    add_sim_step(b, .{
        .seed = seed,
        .target = target,
        .optimize = optimize,
        .zigbox = zigbox_module,
        .library = library,
    });
}

const CModules = struct { sqlite: *std.Build.Module, libpq: *std.Build.Module };

fn add_c_modules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) CModules {
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
    return .{ .sqlite = sqlite, .libpq = libpq_module };
}

/// What `conformance_options` holds when the suite runs against the memory store with the
/// per-run seed: the single-threaded tests in `zig build test` and `zig build wasm-test`.
fn memory_suite_options(b: *std.Build) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(Backend, "backend", .memory);
    options.addOption(?u64, "seed", null);
    return options;
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
    seed: ?u64,
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
    const seed = step_options.seed;
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

/// `zig build wasm` compiles the control-plane core for `wasm32-freestanding`: no libc, no OS, no
/// threads, no `std.Io`. It is the check that the core stays free of the shell (docs/wasm.md).
/// `zig build wasm-check` also runs the result in Node, as CI does.
fn add_wasm_steps(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    // The same package, built for the wasm target: only its pure modules are reachable from the
    // library, so nothing of its host code is compiled.
    const zigbox = b.dependency("zigbox", .{ .target = target, .optimize = optimize });
    const library = b.addExecutable(.{
        .name = "zcube_core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigbox", .module = zigbox.module("zigbox") }},
        }),
    });
    // A library for a host to instantiate: no `_start`, and the exports stay whatever is `export`.
    library.entry = .disabled;
    library.rdynamic = true;
    const install = b.addInstallArtifact(library, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    const step = b.step("wasm", "Compile the control-plane core for wasm32-freestanding");
    step.dependOn(&install.step);

    // Node is the one runtime CI has for WebAssembly; the runner is a few lines of JavaScript
    // (tools/wasm_check.mjs), whose reason is written at its top and in docs/wasm.md.
    const check = b.step("wasm-check", "Run the wasm core in Node and check its result");
    for (v8_modes) |mode| {
        const node = b.addSystemCommand(&.{ "node", "--no-warnings", mode });
        node.addFileArg(b.path("tools/wasm_check.mjs"));
        node.addFileArg(library.getEmittedBin());
        check.dependOn(&node.step);
    }
    add_wasm_test_step(b, optimize);
    return library;
}

const SimStepOptions = struct {
    seed: ?u64,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zigbox: *std.Build.Module,
    library: *std.Build.Step.Compile,
};

/// `zig build sim-c0 [-Dseed=N] [-Dops=N]`: the deterministic simulation of C0 (src/sim_c0.zig),
/// run natively and as WebAssembly for the same seed, and the two reports compared byte for byte.
/// It is a simulation, not `demo-c0`. The scenario and the fuzz variant both run; `-Dops` is the
/// fuzz variant's number of operations. The default seed is 1, so a plain run is reproducible;
/// CI passes its own and prints it.
fn add_sim_step(b: *std.Build, sim: SimStepOptions) void {
    const seed = sim.seed;
    const ops_help = "Operations of the fuzz variant of sim-c0 (default 100)";
    const operations = b.option(u32, "ops", ops_help) orelse 100;
    const exe = b.addExecutable(.{
        .name = "sim_c0",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_c0_main.zig"),
            .target = sim.target,
            .optimize = sim.optimize,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    // The executable alone, for running many seeds by hand: `zig build sim-c0-exe`, then
    // `zig-out/bin/sim_c0 <seed> [fuzz <operations>]` in a loop (build it with ReleaseSafe).
    const install = b.addInstallArtifact(exe, .{});
    const exe_help = "Install the native sim-c0 runner into zig-out/bin";
    b.step("sim-c0-exe", exe_help).dependOn(&install.step);
    const seed_text = b.fmt("{d}", .{seed orelse 1});
    const operations_text = b.fmt("{d}", .{operations});
    const scenario = b.addRunArtifact(exe);
    scenario.addArg(seed_text);
    const scenario_report = scenario.captureStdOut(.{});
    const fuzz = b.addRunArtifact(exe);
    fuzz.addArgs(&.{ seed_text, "fuzz", operations_text });
    const fuzz_report = fuzz.captureStdOut(.{});
    const help = "Run the C0 simulation natively and as WASM, and compare (-Dseed=N)";
    const step = b.step("sim-c0", help);
    for (v8_modes) |mode| {
        const node = b.addSystemCommand(&.{ "node", "--no-warnings", mode });
        node.addFileArg(b.path("tools/wasm_check.mjs"));
        node.addArg("--sim");
        node.addFileArg(sim.library.getEmittedBin());
        node.addArgs(&.{ seed_text, operations_text });
        node.addFileArg(scenario_report);
        node.addFileArg(fuzz_report);
        step.dependOn(&node.step);
    }
}

/// `zig build wasm-test` runs the unit tests of the core modules under WASI in Node: a 32-bit
/// address space and a single thread, with the testing allocator still checking for leaks. It is
/// WASI and not freestanding because `std.testing` needs `std.Io`, which freestanding lacks.
fn add_wasm_test_step(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    // The single-threaded conformance tests run here against the memory store.
    const memory_suite = memory_suite_options(b);
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const zigbox = b.dependency("zigbox", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigbox", .module = zigbox.module("zigbox") },
                .{ .name = "conformance_options", .module = memory_suite.createModule() },
            },
        }),
    });
    const step = b.step("wasm-test", "Run the core modules' unit tests under WASI in Node");
    for (v8_modes) |mode| {
        const node = b.addSystemCommand(&.{ "node", "--no-warnings", mode });
        node.addFileArg(b.path("tools/wasm_check.mjs"));
        node.addArg("--wasi");
        node.addFileArg(tests.getEmittedBin());
        step.dependOn(&node.step);
    }
}

/// `zig build console-wasm` builds the browser module of the console (src/console_wasm.zig: the
/// real core over a memory store and the simulated runtime) in ReleaseSafe, whatever `-Doptimize`
/// says, because `ReleaseSmall` removes the assertions the core relies on. It installs the module
/// at `zig-out/console/sim/zcube_console.wasm` and runs `tools/console_check.mjs` on it under each
/// V8 compiler: exactly one import, and it answers `GET /v1/status`. `zig build console-site`
/// also copies `web/` beside it, so `zig-out/console` is the whole console as static files.
fn add_console_steps(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const zigbox = b.dependency("zigbox", .{ .target = target, .optimize = .ReleaseSafe });
    const module = b.addExecutable(.{
        .name = "zcube_console",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/console_wasm.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .strip = true,
            .imports = &.{.{ .name = "zigbox", .module = zigbox.module("zigbox") }},
        }),
    });
    module.entry = .disabled;
    module.rdynamic = true;
    const install = b.addInstallArtifact(module, .{
        .dest_dir = .{ .override = .{ .custom = "console/sim" } },
    });
    const step = b.step("console-wasm", "Build the console's browser module and check it in Node");
    step.dependOn(&install.step);
    for (v8_modes) |mode| {
        const node = b.addSystemCommand(&.{ "node", "--no-warnings", mode });
        node.addFileArg(b.path("tools/console_check.mjs"));
        node.addFileArg(module.getEmittedBin());
        step.dependOn(&node.step);
    }
    const site_help = "Install the whole console (web/ and its WASM) to zig-out/console";
    const site = b.step("console-site", site_help);
    site.dependOn(step);
    const web = b.addInstallDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .prefix,
        .install_subdir = "console",
    });
    site.dependOn(&web.step);
}
