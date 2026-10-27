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
    // Zigbox's package has a `build_options` module of its own; if the two files were byte for
    // byte the same, the compiler would see one file in two modules. This line keeps them apart.
    options.addOption([]const u8, "product", "zigcube");

    const zigbox = b.dependency("zigbox", .{ .target = target, .optimize = optimize });
    const zigbox_module = zigbox.module("zigbox");

    const c_modules = add_c_modules(b, target, optimize);
    const sqlite = c_modules.sqlite;
    const libpq_module = c_modules.libpq;
    const console = add_console_steps(b);
    const web_files = add_web_files(b, console);

    const built = add_executables(b, .{
        .target = target,
        .optimize = optimize,
        .options = options,
        .zigbox = zigbox_module,
        .sqlite = sqlite,
        .libpq = libpq_module,
        .web_files = web_files,
    });

    add_unit_tests(b, .{
        .target = target,
        .optimize = optimize,
        .options = options,
        .zigbox = zigbox_module,
        .sqlite = sqlite,
        .libpq = libpq_module,
        .web_files = web_files,
    }, built);

    // `-Dseed=N` is one option for two steps (test-store and sim-c0), so it is declared once.
    const seed_help = "Seed for test-store (default: random) and sim-c0 (default: 1)";
    const seed = b.option(u64, "seed", seed_help);
    add_store_and_demo_steps(b, built, seed, .{
        .target = target,
        .optimize = optimize,
        .zigbox = zigbox_module,
        .sqlite = sqlite,
        .libpq = libpq_module,
    });
    add_agent_smoke_step(b, built, zigbox_module);
    add_tidy_step(b);
    add_errors_site_steps(b);
    const library = add_wasm_steps(b, optimize);
    add_sim_step(b, .{
        .seed = seed,
        .target = target,
        .optimize = optimize,
        .zigbox = zigbox_module,
        .library = library,
    });
}

const Shared = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zigbox: *std.Build.Module,
    sqlite: *std.Build.Module,
    libpq: *std.Build.Module,
};

/// The steps that run against a real store. `-Dbackend` and `-Dpostgres` are shared by two of
/// them, so they are declared once, here: test-store (default memory) and demo-c0 (default sqlite).
fn add_store_and_demo_steps(b: *std.Build, built: Built, seed: ?u64, shared: Shared) void {
    const backend = b.option(Backend, "backend", "Store backend for test-store and demo-c0");
    const postgres = postgres_conninfo(b);
    add_store_step(b, .{
        .backend = backend orelse .memory,
        .postgres = postgres,
        .seed = seed,
        .target = shared.target,
        .optimize = shared.optimize,
        .sqlite = shared.sqlite,
        .libpq = shared.libpq,
        .zigbox = shared.zigbox,
    });
    const pg_dev = add_pg_dev_steps(b);
    // The demo needs a real store: `-Dbackend=memory` (which test-store takes) runs it on SQLite.
    const demo_backend: Backend = switch (backend orelse .sqlite) {
        .postgres => .postgres,
        .sqlite, .memory => .sqlite,
    };
    add_demo_step(b, .{
        .built = built,
        .backend = demo_backend,
        .postgres = postgres,
        .target = shared.target,
        .zigbox = shared.zigbox,
        .sqlite = shared.sqlite,
        .libpq = shared.libpq,
        .pg_dev = pg_dev,
    });
}

/// `zig build test`. The single-threaded half of the conformance suite runs here against the
/// memory store; `test-store` runs the whole suite against the backend it is given.
fn add_unit_tests(b: *std.Build, unit: ExecutablesOptions, built: Built) void {
    const memory_suite = memory_suite_options(b);
    const test_step = b.step("test", "Run unit and snapshot tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = unit.target,
            .optimize = unit.optimize,
            .imports = &.{
                .{ .name = "build_options", .module = unit.options.createModule() },
                .{ .name = "conformance_options", .module = memory_suite.createModule() },
                .{ .name = "sqlite_c", .module = unit.sqlite },
                .{ .name = "libpq_c", .module = unit.libpq },
                .{ .name = "zigbox", .module = unit.zigbox },
                .{ .name = "web_files", .module = unit.web_files },
            },
        }),
    });
    const run = b.addRunArtifact(unit_tests);
    // The tests of the fake runtime run real processes, and the supervisor of each is the agent's
    // own executable (`zcube-agent supervise`). The build system of 0.17 knows the install prefix
    // only while it runs, so the tests look for `zig-out/bin/zcube-agent` (or the path in
    // `ZCUBE_AGENT_EXE`) and skip if it is not there; the step installs the agent first and
    // reruns when the agent changes.
    run.step.dependOn(&built.agent_install.step);
    run.addFileInput(built.agent.getEmittedBin());
    test_step.dependOn(&run.step);
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
    sqlite: *std.Build.Module,
    libpq: *std.Build.Module,
    web_files: *std.Build.Module,
};

/// What `add_executables` made that other steps use: the server and the agent, and the steps that
/// install them (the agent-smoke test runs the installed files, as a deployment would).
const Built = struct {
    server: *std.Build.Step.Compile,
    agent: *std.Build.Step.Compile,
    cli: *std.Build.Step.Compile,
    server_install: *std.Build.Step.InstallArtifact,
    agent_install: *std.Build.Step.InstallArtifact,
};

fn add_executables(b: *std.Build, executables_options: ExecutablesOptions) Built {
    const build_options = executables_options.options.createModule();
    var built: Built = undefined;
    for (executables) |executable| {
        const module = b.createModule(.{
            .root_source_file = b.path(executable.root),
            .target = executables_options.target,
            .optimize = executables_options.optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options },
                .{ .name = "zigbox", .module = executables_options.zigbox },
            },
        });
        // The server is the one executable that opens a store and serves the console; the CLI
        // and the agent reach it over HTTP.
        if (std.mem.eql(u8, executable.name, "zcube-server")) {
            module.addImport("sqlite_c", executables_options.sqlite);
            module.addImport("libpq_c", executables_options.libpq);
            module.addImport("web_files", executables_options.web_files);
        }
        const exe = b.addExecutable(.{ .name = executable.name, .root_module = module });
        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);
        if (std.mem.eql(u8, executable.name, "zcube-server")) {
            built.server = exe;
            built.server_install = install;
        }
        if (std.mem.eql(u8, executable.name, "zcube-agent")) {
            built.agent = exe;
            built.agent_install = install;
        }
        if (std.mem.eql(u8, executable.name, "zcube")) built.cli = exe;
    }
    return built;
}

/// `zig build agent-smoke`: the server and the agent as real processes, with real containers
/// (src/agent_smoke.zig). It runs the executables the build made, whatever `-Doptimize` says, and
/// is not `demo-c0`. It never caches: it exists to be run.
fn add_agent_smoke_step(b: *std.Build, built: Built, zigbox_module: *std.Build.Module) void {
    const exe = b.addExecutable(.{
        .name = "agent_smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent_smoke.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zigbox", .module = zigbox_module }},
        }),
    });
    const run = b.addRunArtifact(exe);
    run.addArtifactArg(built.server);
    run.addArtifactArg(built.agent);
    run.addFileArg(b.path("fixtures/images.zon"));
    run.has_side_effects = true;
    const help = "Run zcube-server and zcube-agent as real processes and check them (not demo-c0)";
    b.step("agent-smoke", help).dependOn(&run.step);
}

/// `zig build pg-up` starts a throwaway Postgres for the conformance suite; `pg-down` removes it;
/// `pg-stop` stops it and keeps its data (demo-c0 stops and starts it mid-run). Returns the tool.
fn add_pg_dev_steps(b: *std.Build) *std.Build.Step.Compile {
    const tool = b.addExecutable(.{
        .name = "pg_dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pg_dev.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const commands = [_][]const u8{ "up", "down", "stop" };
    const descriptions = [_][]const u8{
        "Start a throwaway Postgres for test-store (prints its ZCUBE_TEST_POSTGRES)",
        "Stop the throwaway Postgres and delete its files",
        "Stop the throwaway Postgres and keep its files",
    };
    for (commands, descriptions) |command, description| {
        const run = b.addRunArtifact(tool);
        run.addArg(command);
        run.has_side_effects = true;
        const step_name = b.fmt("pg-{s}", .{command});
        b.step(step_name, description).dependOn(&run.step);
    }
    return tool;
}

const DemoStepOptions = struct {
    built: Built,
    backend: Backend,
    postgres: []const u8,
    target: std.Build.ResolvedTarget,
    zigbox: *std.Build.Module,
    sqlite: *std.Build.Module,
    libpq: *std.Build.Module,
    pg_dev: *std.Build.Step.Compile,
};

/// `zig build demo-c0 -Dbackend=sqlite|postgres [-Dtranscript=FILE]`: HANDOFF's C0 demo, run for
/// real (src/demo_c0.zig): the server, one agent and the `zcube` command as real processes. It
/// never caches: it exists to be run. The Postgres run takes the database from `-Dpostgres` or
/// `ZCUBE_TEST_POSTGRES` like test-store, and stops and starts it with `pg_dev stop` and
/// `pg_dev up`, or with the shell commands in `ZCUBE_DEMO_PG_STOP` and `ZCUBE_DEMO_PG_START`
/// (CI's service container is stopped with `docker stop`).
fn add_demo_step(b: *std.Build, step_options: DemoStepOptions) void {
    const transcript_help = "File that demo-c0 writes its transcript to";
    const transcript = b.option([]const u8, "transcript", transcript_help);
    const exe = b.addExecutable(.{
        .name = "demo_c0",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_c0.zig"),
            .target = step_options.target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "zigbox", .module = step_options.zigbox },
                .{ .name = "sqlite_c", .module = step_options.sqlite },
                .{ .name = "libpq_c", .module = step_options.libpq },
            },
        }),
    });
    const run = b.addRunArtifact(exe);
    run.has_side_effects = true;
    const built = step_options.built;
    run.addArg("--backend");
    switch (step_options.backend) {
        .sqlite => run.addArg("sqlite"),
        .postgres => run.addArg("postgres"),
        .memory => unreachable, // `add_store_and_demo_steps` never passes it.
    }
    run.addArg("--zcube");
    run.addArtifactArg(built.cli);
    run.addArg("--server");
    run.addArtifactArg(built.server);
    run.addArg("--agent");
    run.addArtifactArg(built.agent);
    run.addArg("--images");
    run.addFileArg(b.path("fixtures/images.zon"));
    if (step_options.backend == .postgres) {
        add_postgres_control(b, run, step_options.pg_dev, step_options.postgres);
    }
    if (transcript) |path| run.addArgs(&.{ "--transcript", path });
    const help = "Run HANDOFF's C0 demo for real (-Dbackend=sqlite|postgres, -Dtranscript=FILE)";
    b.step("demo-c0", help).dependOn(&run.step);
}

/// The settings of the Postgres the demo runs against, and the commands that stop and start it.
fn add_postgres_control(
    b: *std.Build,
    run: *std.Build.Step.Run,
    pg_dev: *std.Build.Step.Compile,
    conninfo: []const u8,
) void {
    run.addArgs(&.{ "--postgres", conninfo });
    const stop = b.graph.environ_map.get("ZCUBE_DEMO_PG_STOP");
    const start = b.graph.environ_map.get("ZCUBE_DEMO_PG_START");
    if (stop) |command| run.addArgs(&.{ "--pg-stop", command });
    if (start) |command| run.addArgs(&.{ "--pg-start", command });
    if (stop != null and start != null) return;
    // Local default: the throwaway server `zig build pg-up` made.
    run.addArg("--pg-dev");
    run.addArtifactArg(pg_dev);
}

const StoreStepOptions = struct {
    backend: Backend,
    postgres: []const u8,
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
    const backend = step_options.backend;
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
        run.setEnvironmentVariable("ZCUBE_TEST_POSTGRES", step_options.postgres);
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

/// `zig build errors-site` writes site/errors/<code>.html from the diagnostic registry (the page
/// every `ZC-` diagnostic's `docs` line points at); `zig build errors-site-check` (run by CI)
/// fails if a checked-in page is missing or stale.
fn add_errors_site_steps(b: *std.Build) void {
    // A host tool: built for the machine running the build, like tidy. The registry it reads
    // names Zigbox's severity and blame types, so it takes the package too (built for the host).
    const zigbox = b.dependency("zigbox", .{ .target = b.graph.host, .optimize = .Debug });
    const generator = b.addExecutable(.{
        .name = "errors_site",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/errors_site.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zigbox", .module = zigbox.module("zigbox") }},
        }),
    });
    const write = b.addRunArtifact(generator);
    write.setCwd(b.path("."));
    write.addArg("site/errors");
    const write_step = b.step("errors-site", "Write site/errors/<code>.html from the registry");
    write_step.dependOn(&write.step);

    const check = b.addRunArtifact(generator);
    check.setCwd(b.path("."));
    check.addArgs(&.{ "site/errors", "--check" });
    const check_step = b.step("errors-site-check", "Fail if site/errors is stale");
    check_step.dependOn(&check.step);
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
fn add_console_steps(b: *std.Build) *std.Build.Step.Compile {
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
    return module;
}

/// The console's files as a Zig module for `zcube-server` to embed: `src/web_embed.zig` copies
/// `web/` and the browser WASM module beside a generated table of `@embedFile`s.
fn add_web_files(b: *std.Build, console: *std.Build.Step.Compile) *std.Build.Module {
    const tool = b.addExecutable(.{
        .name = "web_embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_embed.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(tool);
    const out = run.addOutputDirectoryArg("web_embed");
    run.addDirectoryArg(b.path("web"));
    run.addFileArg(console.getEmittedBin());
    return b.createModule(.{ .root_source_file = out.path(b, "web_files.zig") });
}
