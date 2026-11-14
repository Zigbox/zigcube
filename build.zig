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

/// Which stores `zcube-server` compiles in, besides the memory store (`-Dstore=`). `all` is the
/// default for development and CI; the packaged servers each hold one, so a machine installs
/// only the library of the store it uses.
const StoreChoice = enum { all, sqlite, postgres };

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
    const store_help = "Stores zcube-server compiles in besides memory (default all)";
    const store_choice = b.option(StoreChoice, "store", store_help) orelse .all;
    options.addOption(StoreChoice, "store", store_choice);

    const zigbox = b.dependency("zigbox", .{ .target = target, .optimize = optimize });
    const zigbox_module = zigbox.module("zigbox");

    const c_modules = add_c_modules(b, target, optimize);
    const sqlite = c_modules.sqlite;
    const libpq_module = c_modules.libpq;
    const console = add_console_steps(b);
    const web_files = add_web_files(b, console);

    const shared_options: ExecutablesOptions = .{
        .target = target,
        .optimize = optimize,
        .options = options,
        .zigbox = zigbox_module,
        .sqlite = sqlite,
        .libpq = libpq_module,
        .web_files = web_files,
        .store = store_choice,
    };
    const built = add_executables(b, shared_options);
    add_unit_tests(b, shared_options, built);

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
    add_swarm_smoke_steps(b, shared_options, built);
    add_mtls_interop_step(b, shared_options);
    add_mtls_teeth_step(b, shared_options);
    add_local_smoke_step(b, built);
    add_x509_format_step(b, zigbox_module);
    add_bench_watch_step(b, shared_options);
    add_zigbox_smoke_step(b, built);
    add_tidy_step(b);
    add_packages_steps(b);
    add_errors_site_steps(b);
    const library = add_wasm_steps(b, optimize);
    add_sim_steps(b, .{
        .seed = seed,
        .target = target,
        .optimize = optimize,
        .zigbox = zigbox_module,
        .library = library,
        .ops = 0,
    });
    add_check_step(b);
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
    const store_help = "Run the store conformance suite (-Dbackend=...)";
    const store_options: StoreStepOptions = .{
        .backend = backend orelse .memory,
        .postgres = postgres,
        .seed = seed,
        .target = shared.target,
        .optimize = shared.optimize,
        .sqlite = shared.sqlite,
        .libpq = shared.libpq,
        .zigbox = shared.zigbox,
    };
    add_store_step(b, "test-store", store_help, store_options);
    // `check` runs the suite on the two backends that need no server, as steps of its own: the
    // `test-store` step takes one backend from the command line.
    for ([_]Backend{ .memory, .sqlite }) |fixed| {
        var options = store_options;
        options.backend = fixed;
        const name = b.fmt("check-store-{s}", .{@tagName(fixed)});
        add_store_step(b, name, "Run the store conformance suite for check", options);
    }
    const pg_dev = add_pg_dev_steps(b);
    const failover_help = "test-store-faults on Postgres: also run the failover runs " ++
        "(default true; they need the Postgres 16 programs, as pg-up does)";
    add_store_faults_step(b, store_options, .{
        .enabled = b.option(bool, "failover", failover_help) orelse true,
        .pg_dev = pg_dev,
        .server = built.server,
    });
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
    const filters = b.option([]const []const u8, "test-filter", "Run only matching tests");
    const unit_tests = b.addTest(.{
        .filters = filters orelse &.{},
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
    // Zigbox's `constants.zig` is not exported by its `zigbox` module, and a file cannot belong to
    // two modules, so `src/zigbox_limits_test.zig` embeds the pinned file as text.
    unit_tests.root_module.addAnonymousImport("zigbox_constants_text", .{
        .root_source_file = b.dependency("zigbox", .{}).path("src/constants.zig"),
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
    // The gate's own tests (src/testing/check.zig): `check` must fail over a reported failure.
    const check_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/check.zig"),
            .target = b.graph.host,
        }),
    });
    const check_run = b.addRunArtifact(check_tests);
    check_run.setCwd(b.path("."));
    test_step.dependOn(&check_run.step);
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
    store: StoreChoice,
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
            // Only the stores built in are imported, so only their libraries are linked.
            if (executables_options.store != .postgres) {
                module.addImport("sqlite_c", executables_options.sqlite);
            }
            if (executables_options.store != .sqlite) {
                module.addImport("libpq_c", executables_options.libpq);
            }
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

/// `zig build swarm-smoke` and `swarm-smoke-teeth` (src/swarm_smoke.zig): three agents, a fake
/// registry and a corrupt peer on real processes. The teeth step runs the same program with an
/// agent whose fetch plan skips the hash check (src/zcube_agent_teeth.zig) and passes only if the
/// smoke fails. Never cached, not in `check`, not demo-c0.
fn add_swarm_smoke_steps(b: *std.Build, options: ExecutablesOptions, built: Built) void {
    const exe = b.addExecutable(.{
        .name = "swarm_smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/swarm_smoke.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zigbox", .module = options.zigbox }},
        }),
    });
    const teeth_agent = b.addExecutable(.{
        .name = "zcube-agent-teeth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zcube_agent_teeth.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.options.createModule() },
                .{ .name = "zigbox", .module = options.zigbox },
            },
        }),
    });
    // Both are built by plain `zig build`, so neither smoke can stop compiling unnoticed.
    b.installArtifact(exe);
    b.getInstallStep().dependOn(&teeth_agent.step);
    const run = b.addRunArtifact(exe);
    run.addArtifactArg(built.server);
    run.addArtifactArg(built.agent);
    run.has_side_effects = true;
    const help = "Run three agents, a fake registry and a corrupt peer as real processes " ++
        "(not demo-c0)";
    b.step("swarm-smoke", help).dependOn(&run.step);
    const teeth = b.addRunArtifact(exe);
    teeth.addArtifactArg(built.server);
    teeth.addArtifactArg(teeth_agent);
    teeth.has_side_effects = true;
    teeth.expectExitCode(4); // swarm_smoke.exit_unverified: the plan took a bad chunk.
    const teeth_help = "swarm-smoke with the fetch plan's test-only fault on; it must fail";
    b.step("swarm-smoke-teeth", teeth_help).dependOn(&teeth.step);
}

/// `zig build mtls-teeth`: the tests named `teeth:` of the mTLS files (src/mtls_teeth.zig). Each
/// switches one check off and passes only if the matching test then fails.
fn add_mtls_teeth_step(b: *std.Build, options: ExecutablesOptions) void {
    const tests = b.addTest(.{
        .filters = &.{"teeth:"},
        .test_runner = .{ .path = b.path("src/mtls_teeth_runner.zig"), .mode = .simple },
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mtls_teeth.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{.{ .name = "zigbox", .module = options.zigbox }},
        }),
    });
    const run = b.addRunArtifact(tests);
    b.step("mtls-teeth", "Run the mTLS teeth tests: each skipped check must be caught")
        .dependOn(&run.step);
}

/// `zig build mtls-interop` (src/mtls_interop.zig): the mTLS client against `openssl s_server` and
/// a JDK 21 server. Needs OpenSSL and a JDK, so it is not in `check`; CI runs it in a job of its
/// own. An interop check, never a demo.
fn add_mtls_interop_step(b: *std.Build, options: ExecutablesOptions) void {
    const exe = b.addExecutable(.{
        .name = "mtls_interop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mtls_interop.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zigbox", .module = options.zigbox }},
        }),
    });
    // Plain `zig build` keeps it compiling and installs nothing.
    b.getInstallStep().dependOn(&exe.step);
    const run = b.addRunArtifact(exe);
    run.addFileArg(b.path("ops/mtls-interop/InteropServer.java"));
    run.has_side_effects = true;
    const help = "Run the mTLS client against openssl s_server and a JDK 21 server (not a demo)";
    b.step("mtls-interop", help).dependOn(&run.step);
}

/// `zig build local-smoke`: `zcube local up` and `down` as a person would use them
/// (src/local_smoke.zig), on copies of the executables the build made. Never cached, not in
/// `check`, not demo-c0.
fn add_local_smoke_step(b: *std.Build, built: Built) void {
    const exe = b.addExecutable(.{
        .name = "local_smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/local_smoke.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(exe);
    // The smoke copies the three executables into a directory of its own: the 0.17 build system
    // does not tell a build script the install prefix, and `zcube local` finds the server and
    // the agent beside itself.
    run.addArtifactArg(built.cli);
    run.addArtifactArg(built.server);
    run.addArtifactArg(built.agent);
    run.has_side_effects = true;
    const help = "Run zcube local up and down against real processes (not demo-c0)";
    b.step("local-smoke", help).dependOn(&run.step);
}

/// `zig build x509-format`: the certificates `src/x509.zig` writes, read by openssl, keytool and
/// the JDK (src/x509_format_check.zig, tools/mtls/X509Dump.java). Never cached, not in `check`.
fn add_x509_format_step(b: *std.Build, zigbox_module: *std.Build.Module) void {
    const exe = b.addExecutable(.{
        .name = "x509_format_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/x509_format_check.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zigbox", .module = zigbox_module }},
        }),
    });
    const run = b.addRunArtifact(exe);
    run.addFileArg(b.path("tools/mtls/X509Dump.java"));
    run.has_side_effects = true;
    const help = "Check the certificates against openssl, keytool and the JDK (test tooling)";
    b.step("x509-format", help).dependOn(&run.step);
}

/// `zig build bench-watch`: the watch fan-out row of docs/c1.md (src/bench_watch.zig), a real
/// server over SQLite with 50 held agent polls in one process. Never cached, not in `check`; a
/// miss is the result, and the exit code says so.
fn add_bench_watch_step(b: *std.Build, options: ExecutablesOptions) void {
    const exe = b.addExecutable(.{
        .name = "bench_watch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_watch.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.options.createModule() },
                .{ .name = "zigbox", .module = options.zigbox },
                .{ .name = "sqlite_c", .module = options.sqlite },
                .{ .name = "libpq_c", .module = options.libpq },
                .{ .name = "web_files", .module = options.web_files },
            },
        }),
    });
    const run = b.addRunArtifact(exe);
    run.has_side_effects = true;
    run.setCwd(b.path("."));
    b.step("bench-watch", "Run the watch fan-out benchmark (50 agents, 2,000 assignments)")
        .dependOn(&run.step);
}

/// `zig build zigbox-smoke`: the Zigbox runtime on a real host, in a QEMU guest booted through
/// Zigbox's exported `zigbox_vm` module (src/zigbox_smoke.zig). Skips unless `ZCUBE_REAL_HOST=1`.
fn add_zigbox_smoke_step(b: *std.Build, built: Built) void {
    const vm = b.dependency("zigbox", .{}).module("zigbox_vm");
    // The guest runs the host's architecture; Zigbox's zbx is static and libc-free, and the guest
    // gets it only to run `zbx doctor` for the log of a failure.
    const zbx = b.dependency("zigbox", .{ .target = b.graph.host, .optimize = .ReleaseSafe })
        .artifact("zbx");
    const exe = b.addExecutable(.{
        .name = "zigbox_smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zigbox_smoke.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zigbox_vm", .module = vm }},
        }),
    });
    const run = b.addRunArtifact(exe);
    run.addFileArg(stripped(b, built.agent));
    run.addFileArg(stripped(b, built.server));
    run.addFileArg(stripped(b, zbx));
    run.addFileArg(b.path("ops/zigbox-smoke/guest.sh"));
    run.has_side_effects = true;
    const help = "Run the Zigbox runtime on a real host in a QEMU guest (needs ZCUBE_REAL_HOST=1)";
    b.step("zigbox-smoke", help).dependOn(&run.step);
}

/// A copy of `exe` without symbols: the guest harness serves files of at most 8 MiB, which a
/// ReleaseSafe build with debug information exceeds (binutils' `strip`; `zig objcopy` cannot).
fn stripped(b: *std.Build, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ "strip", "-o" });
    const output = run.addOutputFileArg(exe.name);
    run.addArtifactArg(exe);
    return output;
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
    const commands = [_][]const u8{ "up", "down", "stop", "pair-down" };
    const descriptions = [_][]const u8{
        "Start a throwaway Postgres for test-store (prints its ZCUBE_TEST_POSTGRES)",
        "Stop the throwaway Postgres and delete its files",
        "Stop the throwaway Postgres and keep its files",
        "Stop the failover runs' primary and standby and delete their files",
    };
    for (commands, descriptions) |command, description| {
        const run = b.addRunArtifact(tool);
        run.addArg(command);
        run.has_side_effects = true;
        // The pair's default ports and directory come from the working directory (pg_dev.zig).
        run.setCwd(b.path("."));
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
    add_demo_c1_step(b, step_options, transcript);
    add_demo_b1_step(b, step_options, transcript);
    add_demo_c2_step(b, step_options, transcript);
    add_demo_b3_step(b, step_options, transcript);
}

/// `zig build demo-c1 -Dbackend=sqlite|postgres [-Dtranscript=FILE]`: HANDOFF's C1 demo, run for
/// real (src/demo_c1.zig): the server, three agents and the `zcube` command as real processes.
/// It does not stop the database, so it needs no `pg-up` control.
fn add_demo_c1_step(b: *std.Build, step_options: DemoStepOptions, transcript: ?[]const u8) void {
    const exe = b.addExecutable(.{
        .name = "demo_c1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_c1.zig"),
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
        .postgres => run.addArgs(&.{ "postgres", "--postgres", step_options.postgres }),
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
    if (transcript) |path| run.addArgs(&.{ "--transcript", path });
    const help = "Run HANDOFF's C1 demo for real (-Dbackend=sqlite|postgres, -Dtranscript=FILE)";
    b.step("demo-c1", help).dependOn(&run.step);
}

/// `zig build demo-b1 -Dbackend=sqlite|postgres [-Dtranscript=FILE]`: B1's demo, run for
/// real (src/demo_b1.zig): the server, two agents and the `zcube` command as real processes.
/// It does not stop the database, so it needs no `pg-up` control.
fn add_demo_b1_step(b: *std.Build, step_options: DemoStepOptions, transcript: ?[]const u8) void {
    const exe = b.addExecutable(.{
        .name = "demo_b1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_b1.zig"),
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
        .postgres => run.addArgs(&.{ "postgres", "--postgres", step_options.postgres }),
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
    if (transcript) |path| run.addArgs(&.{ "--transcript", path });
    const help = "Run B1's demo for real (-Dbackend=sqlite|postgres, -Dtranscript=FILE)";
    b.step("demo-b1", help).dependOn(&run.step);
}

/// `zig build demo-c2 [-Dtranscript=FILE]`: SPEC's C2 demo, run for real (src/demo_c2.zig): the
/// server on the host over SQLite, four QEMU guests booted through Zigbox's `zigbox_vm`, each
/// with one `zcube-agent --runtime zigbox`. Skips unless `ZCUBE_REAL_HOST=1`.
fn add_demo_c2_step(b: *std.Build, step_options: DemoStepOptions, transcript: ?[]const u8) void {
    const zigbox = b.dependency("zigbox", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
    const exe = b.addExecutable(.{
        .name = "demo_c2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_c2.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zigbox", .module = step_options.zigbox },
                .{ .name = "zigbox_vm", .module = b.dependency("zigbox", .{}).module("zigbox_vm") },
            },
        }),
    });
    const run = b.addRunArtifact(exe);
    run.has_side_effects = true;
    const built = step_options.built;
    run.addArg("--zcube");
    run.addArtifactArg(built.cli);
    run.addArg("--server");
    run.addArtifactArg(built.server);
    run.addArg("--agent");
    run.addFileArg(stripped(b, built.agent));
    run.addArg("--zbx");
    run.addFileArg(stripped(b, zigbox.artifact("zbx")));
    run.addArg("--guest-script");
    run.addFileArg(b.path("ops/demo-c2/guest.sh"));
    if (transcript) |path| run.addArgs(&.{ "--transcript", path });
    const help = "Run SPEC's C2 demo for real in four QEMU guests (needs ZCUBE_REAL_HOST=1)";
    b.step("demo-c2", help).dependOn(&run.step);
}

/// `zig build demo-b3 [-Dtranscript=FILE]`: B3's demo, run for real (src/demo_b3.zig): the server
/// on the host with one relay, one QEMU guest with `zcube-agent --runtime zigbox`, a relayed job
/// that tries to reach the world. Skips unless `ZCUBE_REAL_HOST=1`.
fn add_demo_b3_step(b: *std.Build, step_options: DemoStepOptions, transcript: ?[]const u8) void {
    const zigbox = b.dependency("zigbox", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
    const exe = b.addExecutable(.{
        .name = "demo_b3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_b3.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zigbox", .module = step_options.zigbox },
                .{ .name = "zigbox_vm", .module = b.dependency("zigbox", .{}).module("zigbox_vm") },
            },
        }),
    });
    // demo-b3 runs only on KVM hosts, so `check` compiles it (no run) and runs the tests of its
    // script (the job's command line must fit the CLI's argument limit): what a comptime assert,
    // a type error or an over-long argument would otherwise show only in CI's demo-b3 job.
    const script_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_b3_script.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zigbox", .module = step_options.zigbox },
                .{ .name = "zigbox_vm", .module = b.dependency("zigbox", .{}).module("zigbox_vm") },
            },
        }),
    });
    const build_step = b.step("demo-b3-build", "Compile demo-b3 and test its script, no run");
    build_step.dependOn(&exe.step);
    build_step.dependOn(&b.addRunArtifact(script_tests).step);
    const run = b.addRunArtifact(exe);
    run.has_side_effects = true;
    const built = step_options.built;
    run.addArg("--zcube");
    run.addArtifactArg(built.cli);
    run.addArg("--server");
    run.addArtifactArg(built.server);
    run.addArg("--agent");
    run.addFileArg(stripped(b, built.agent));
    run.addArg("--zbx");
    run.addFileArg(stripped(b, zigbox.artifact("zbx")));
    run.addArg("--guest-script");
    run.addFileArg(b.path("ops/demo-b3/guest.sh"));
    if (transcript) |path| run.addArgs(&.{ "--transcript", path });
    const help = "Run B3's demo for real in a QEMU guest (needs ZCUBE_REAL_HOST=1)";
    b.step("demo-b3", help).dependOn(&run.step);
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
fn add_store_step(
    b: *std.Build,
    name: []const u8,
    help: []const u8,
    step_options: StoreStepOptions,
) void {
    const run = add_store_tests(b, step_options, false);
    b.step(name, help).dependOn(&run.step);
}

/// The conformance test binary and its run. `proxied` points every connection of a Postgres
/// run at a fault proxy that adds latency, bandwidth limits and short stalls (never a cut: the
/// suite's tests assert exact outcomes, which a cut connection would turn into errors).
fn add_store_tests(
    b: *std.Build,
    step_options: StoreStepOptions,
    proxied: bool,
) *std.Build.Step.Run {
    const backend = step_options.backend;
    const seed = step_options.seed;
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
        if (proxied) run.setEnvironmentVariable("ZCUBE_TEST_PROXY", "1");
    }
    return run;
}

/// `zig build test-store-faults -Dbackend=postgres|sqlite [-Dseed=N] [-Dpostgres=...]`: client
/// threads against a store behind the fault proxy (Postgres) or alone (SQLite), every call
/// recorded and checked (src/store_faults.zig). Never cached; there is no default backend that
/// needs no database, so `memory` runs on SQLite's step options and is refused.
/// Slice 10d's failover runs (`src/store_failover.zig`): a `pg_dev` pair and a real server.
const FailoverOptions = struct {
    enabled: bool,
    pg_dev: *std.Build.Step.Compile,
    server: *std.Build.Step.Compile,
};

fn add_store_faults_step(
    b: *std.Build,
    step_options: StoreStepOptions,
    failover: FailoverOptions,
) void {
    const step = b.step("test-store-faults", "Run the store fault tests (-Dbackend=...)");
    const exe = b.addExecutable(.{
        .name = "store_faults",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/store_faults.zig"),
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
    run.setCwd(b.path("."));
    switch (step_options.backend) {
        .postgres => {
            run.addArgs(&.{ "--backend", "postgres", "--postgres", step_options.postgres });
            // The conformance suite's tests, through a proxy that delays and stalls but never cuts.
            step.dependOn(&add_store_tests(b, step_options, true).step);
        },
        .sqlite => run.addArgs(&.{ "--backend", "sqlite" }),
        .memory => {
            step.dependOn(&b.addFail("test-store-faults needs -Dbackend=postgres or sqlite").step);
            return;
        },
    }
    if (step_options.seed) |seed| run.addArgs(&.{ "--seed", b.fmt("{d}", .{seed}) });
    step.dependOn(&run.step);
    if (step_options.backend != .postgres) return;
    if (!failover.enabled) return;
    // One after the other, after 10c's run: each makes and removes the same pair of servers.
    var before: *std.Build.Step = &run.step;
    for ([_][]const u8{ "sync", "async" }) |mode| {
        const failover_run = b.addRunArtifact(exe);
        failover_run.has_side_effects = true;
        failover_run.setCwd(b.path("."));
        failover_run.addArgs(&.{ "--backend", "postgres", "--failover", mode, "--pg-dev" });
        failover_run.addArtifactArg(failover.pg_dev);
        failover_run.addArg("--server");
        failover_run.addArtifactArg(failover.server);
        if (step_options.seed) |seed| {
            failover_run.addArgs(&.{ "--seed", b.fmt("{d}", .{seed}) });
        }
        failover_run.step.dependOn(before);
        before = &failover_run.step;
        step.dependOn(&failover_run.step);
    }
}

/// `zig build packages -Dbin=DIR -Dzigbox-version=V` writes the apt and dnf trees of the Zigcube
/// packages under `zig-out/packages/`; `-Dsignatures=<dir>` adds the owner's signatures,
/// `-Dtest-key` signs with the fixed test key (CI). `packages-check` places the same files, then
/// checks every digest. `-Dbin` holds the executables the release job built (the servers come
/// from a RHEL 9 container, so the build graph cannot make them). It never runs `gpg`: it prints
/// the commands (docs/releases/packaging.md).
fn add_packages_steps(b: *std.Build) void {
    const bin = b.option([]const u8, "bin", "Directory of the built executables for `packages`");
    const zigbox_help = "Version of the zigbox package that zigbox-dev depends on";
    const zigbox_version = b.option([]const u8, "zigbox-version", zigbox_help);
    const signatures_help = "Directory of the owner's signatures for `packages`";
    const signatures = b.option([]const u8, "signatures", signatures_help);
    const test_key_help = "Sign the packages with the fixed test key";
    const test_key = b.option(bool, "test-key", test_key_help) orelse false;
    const tool = package_tool(b);
    var steps: [2]*std.Build.Step.Run = undefined;
    for (&steps, [_]bool{ false, true }) |*slot, checking| {
        const run = b.addRunArtifact(tool);
        run.setCwd(b.path("."));
        run.addArgs(&.{ "--version", @import("build.zig.zon").version });
        run.addArgs(&.{ "--zigbox-version", zigbox_version orelse "0.0.0" });
        run.addArgs(&.{ "--bin", bin orelse "zig-out/release-bin" });
        run.addArgs(&.{ "--assets", "packaging", "--license", "LICENSE" });
        run.addArgs(&.{ "--out", "zig-out/packages" });
        if (signatures) |directory| run.addArgs(&.{ "--signatures", directory });
        if (test_key) run.addArg("--test-key");
        if (checking) run.addArg("--check");
        run.has_side_effects = true;
        slot.* = run;
    }
    steps[1].step.dependOn(&steps[0].step);
    b.step("packages", "Write the apt and dnf trees of the Zigcube packages")
        .dependOn(&steps[0].step);
    b.step("packages-check", "Place the signatures, then check every package file")
        .dependOn(&steps[1].step);
}

fn package_tool(b: *std.Build) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "package_main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/package_main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
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
    // sim-cluster nests deeper than the 1 MiB default allows (2 MiB still traps, 4 MiB passes).
    library.stack_size = 8 * 1024 * 1024;
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
    /// `-Dops`: operations of the fuzz variants of sim-c0 and sim-cluster.
    ops: u32,
    /// `-Dprofile`: the fault profile of sim-cluster and sim-c1 (`auto` draws it from the seed).
    profile: []const u8 = "mixed",
    /// `-Dswarm-profile`: the peer profile of sim-swarm.
    swarm_profile: []const u8 = "mixed",
    /// `-Dauto-shape`: sim-cluster, sim-c1 and sim-swarm draw their operations (and the cluster
    /// its nodes, lease ttl and replica counts) from the seed; `-Dops` and `-Dnodes` are ignored.
    auto_shape: bool = false,
};

/// The operations argument of a simulator: `auto` or the number.
fn ops_argument(b: *std.Build, sim: SimStepOptions) []const u8 {
    return if (sim.auto_shape) "auto" else b.fmt("{d}", .{sim.ops});
}

/// `zig build sim-c0 [-Dseed=N] [-Dops=N]`: the deterministic simulation of C0 (src/sim_c0.zig),
/// run natively and as WebAssembly for the same seed, and the two reports compared byte for byte.
/// It is a simulation, not `demo-c0`. The scenario and the fuzz variant both run; `-Dops` is the
/// fuzz variant's number of operations. The default seed is 1, so a plain run is reproducible;
/// CI passes its own and prints it.
fn add_sim_step(b: *std.Build, sim: SimStepOptions) void {
    const seed = sim.seed;
    const operations = sim.ops;
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

/// Declares `-Dops` once, for sim-c0's fuzz variant and sim-cluster alike.
fn add_sim_steps(b: *std.Build, options: SimStepOptions) void {
    const ops_help = "Operations of the fuzz variants of sim-c0 and sim-cluster (default 100)";
    var sim = options;
    sim.ops = b.option(u32, "ops", ops_help) orelse 100;
    const profile_help = "Fault profile of sim-cluster and sim-c1: mixed (default), partitions, " ++
        "skew, crash_heavy, slow_store, auto";
    sim.profile = b.option([]const u8, "profile", profile_help) orelse "mixed";
    const swarm_help = "Peer profile of sim-swarm: mixed (default), liars, silent, refusers, " ++
        "honest, auto";
    sim.swarm_profile = b.option([]const u8, "swarm-profile", swarm_help) orelse "mixed";
    const shape_help = "Draw operations (and nodes, lease ttl, replicas) from the seed";
    sim.auto_shape = b.option(bool, "auto-shape", shape_help) orelse false;
    add_sim_step(b, sim);
    add_sim_cluster_step(b, sim);
    add_sim_swarm_step(b, sim);
    add_sim_fleet_step(b, sim);
    add_sim_teeth_step(b, sim);
    add_sim_c1_steps(b, sim);
    add_sim_swarm_teeth_step(b, sim);
    add_sim_canary_step(b);
}

/// `zig build sim-canary-exe` installs every fault-on runner the fleet's teeth canary runs
/// (`ops/sim-fleet/run.sh`, `canary_pick`): `sim_teeth`, `sim_swarm_teeth` and the six
/// `sim_c1_teeth_*`, and `share/sim-fleet/canaries.txt`, the manifest `run.sh` reads them from.
fn add_sim_canary_step(b: *std.Build) void {
    const canary = b.step("sim-canary-exe", "Install the fault-on runners of the fleet's canary");
    const names = [_][]const u8{ "sim-teeth-exe", "sim-swarm-teeth-exe", "sim-c1-teeth-exe" };
    for (names) |name| canary.dependOn(&b.top_level_steps.get(name).?.step);
    const files = b.addWriteFiles();
    const manifest = files.add("canaries.txt", canary_manifest(b));
    const install = b.addInstallFileWithDir(manifest, .prefix, "share/sim-fleet/canaries.txt");
    canary.dependOn(&install.step);
}

/// One line per canary runner, in the order the fleet cycles through them:
/// `<runner> <kind> <seeds> <symptom>`, where the kind names the parser of its output
/// (`sim_fleet ingest --kind`) and the symptom, the rest of the line, is the text a failure's
/// check must start with (`-` for any failure). Generated from `c1_teeth_roots`, so the fleet
/// cannot drift from the teeth tests.
fn canary_manifest(b: *std.Build) []const u8 {
    var text: []const u8 = b.fmt("# Generated by build.zig (canary_manifest); read by " ++
        "ops/sim-fleet/run.sh.\nsim_teeth sim-cluster {d} {s}\n", .{
        canary_seeds_teeth, canary_symptom_teeth,
    });
    for (c1_teeth_roots) |entry| {
        const seeds = if (entry.canary_first) |first|
            b.fmt("{d}+{d}@{d}", .{ first, entry.canary_seeds, entry.ops })
        else
            b.fmt("{d}", .{entry.canary_seeds});
        text = b.fmt("{s}sim_c1_teeth_{s} sim-c1 {s} {s}\n", .{
            text, entry.name, seeds, entry.symptom,
        });
        for (entry.also_seeds) |seed| {
            text = b.fmt("{s}sim_c1_teeth_{s} sim-c1 {d}+1@{d} {s}\n", .{
                text, entry.name, seed, entry.ops, entry.symptom,
            });
        }
    }
    return b.fmt("{s}sim_swarm_teeth sim-swarm {d} {s}\n", .{
        text, canary_seeds_swarm_teeth, canary_symptom_swarm_teeth,
    });
}

/// `zig build sim-cluster [-Dseed=N] [-Dops=N] [-Dnodes=N] [-Dliveness=false]`: the cluster
/// simulation (src/sim_cluster.zig), run natively and as WebAssembly for the same seed, and the
/// two reports compared byte for byte, as sim-c0 does. `-Dnodes=0` lets the seed pick; `-Dops` is
/// sim-c0's too; liveness is on unless `-Dliveness=false`.
fn add_sim_cluster_step(b: *std.Build, sim: SimStepOptions) void {
    const exe = b.addExecutable(.{
        .name = "sim_cluster",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_cluster_main.zig"),
            .target = sim.target,
            .optimize = sim.optimize,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    const exe_help = "Install the native sim-cluster runner into zig-out/bin";
    b.step("sim-cluster-exe", exe_help).dependOn(&install.step);
    const nodes = b.option(u32, "nodes", "Nodes of sim-cluster (default: the seed picks)") orelse 0;
    const live_help = "sim-cluster: faults end, the world must converge (default true)";
    const liveness = b.option(bool, "liveness", live_help) orelse true;
    const seed_text = b.fmt("{d}", .{sim.seed orelse 1});
    const ops_text = ops_argument(b, sim);
    const nodes_text = b.fmt("{d}", .{if (sim.auto_shape) 0 else nodes});
    const liveness_text: []const u8 = if (liveness) "true" else "false";
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{ seed_text, ops_text, nodes_text });
    run.addArg(b.fmt("--liveness={s}", .{liveness_text}));
    run.addArg(b.fmt("--profile={s}", .{sim.profile}));
    const native_report = run.captureStdOut(.{});
    const help = "Run the cluster simulation natively and as WASM, and compare (-Dseed=N)";
    const step = b.step("sim-cluster", help);
    for (v8_modes) |mode| {
        const node = b.addSystemCommand(&.{ "node", "--no-warnings", mode });
        node.addFileArg(b.path("tools/wasm_check.mjs"));
        node.addArg("--sim-cluster");
        node.addFileArg(sim.library.getEmittedBin());
        node.addArgs(&.{ seed_text, ops_text, nodes_text, liveness_text, sim.profile });
        node.addFileArg(native_report);
        step.dependOn(&node.step);
    }
}

/// The negative tests of sim-c1 (docs/authority.md §4, docs/core.md "sim-c1"): each root file
/// declares one test-only switch (`src/c1_teeth.zig`), and the check it breaks. `canary_seeds` is
/// the range the fleet's canary runs it over (`canary_manifest`), sized from its measured catch
/// rate so that a working check is missed with probability below 1e-9 (ops/sim-fleet/README.md).
const c1_teeth_roots = [_]struct {
    name: []const u8,
    root: []const u8,
    symptom: []const u8,
    canary_seeds: u32,
    /// A sparse tooth's canary runs `canary_seeds` seeds from this one at `ops` operations and
    /// the runner's default profile (manifest `FIRST+COUNT@OPS`), not fresh seeds at drawn
    /// operations: ops/sim-fleet/README.md.
    canary_first: ?u32 = null,
    /// More known hits of a sparse tooth, each pinned on its own: `sim-c1-teeth-NAME` also runs
    /// each alone and it must fail with `symptom`, and the manifest gets a line `SEED+1@OPS` of
    /// its own for each, so the canary rests on more than one seed (PR #250 review).
    also_seeds: []const u32 = &.{},
    /// The first seed `sim-c1-teeth-NAME` runs. The test stops at the first failing seed and
    /// that one must show `symptom`, unless `any_symptom`: then seeds that fail otherwise (the
    /// skew world fails on convergence at some seeds since #177) are skipped, and some seed in
    /// the range must show `symptom`.
    first_seed: u32 = 1,
    any_symptom: bool = false,
    /// The last seed the negative test runs (it stops at the first that fails). The offline
    /// world fails J8 on about one seed in seven, so ten seeds were a coin flip that any change
    /// of the draws could lose (#171: its first hit moved from seed 10 to 13).
    seeds: u32 = teeth_seeds_max,
    /// B2 slice 4: the symptom this tooth must make a plain run (no `--c1`) fail with, or null
    /// when its check needs the per-revision tap (`job_double`). Measured 2026-11-08 over seeds
    /// 1 to 40 at 100 operations: restart 36, claim 40, rewrite 39 (as J4: J3 is a `--c1` check),
    /// cancel 13, deadline 26, deadline_late 26, deadline_offline 8, gap 23, stale 40 (as J10: J9
    /// is a `--c1` check) and refused_loop 30 seeds fail.
    plain_symptom: ?[]const u8 = null,
    plain_seeds: u32 = teeth_seeds_max,
    /// Operations of a run; the worlds of the two teeth outside `c1_teeth_operations` need more.
    ops: u32 = c1_teeth_operations,
}{
    .{
        .name = "allocation",
        .root = "src/sim_c1_teeth_allocation_main.zig",
        .symptom = "I6",
        .canary_seeds = 20,
    },
    .{
        .name = "readiness",
        .root = "src/sim_c1_teeth_readiness_main.zig",
        .symptom = "I7",
        .canary_seeds = 20,
    },
    .{
        .name = "stale",
        .root = "src/sim_c1_teeth_stale_main.zig",
        .symptom = "I3",
        .canary_seeds = 20,
    },
    .{
        .name = "skew",
        .root = "src/sim_c1_teeth_skew_main.zig",
        .symptom = "I1b",
        .canary_seeds = 30,
        .any_symptom = true,
    },
    .{
        .name = "wedge",
        .root = "src/sim_c1_teeth_wedge_main.zig",
        .symptom = "I1b: a replaced replica kept executing longer",
        .canary_seeds = 40,
    },
    .{
        .name = "locality",
        .root = "src/sim_c1_teeth_locality_main.zig",
        .symptom = "L1",
        .canary_seeds = 30,
    },
    .{
        .name = "job_restart",
        .root = "src/sim_c1_teeth_job_restart_main.zig",
        .symptom = "J2",
        .canary_seeds = 40,
        .plain_symptom = "J2",
    },
    .{
        .name = "job_claim",
        .root = "src/sim_c1_teeth_job_claim_main.zig",
        .symptom = "J7",
        .canary_seeds = 40,
        .plain_symptom = "J7",
    },
    .{
        .name = "job_double",
        .root = "src/sim_c1_teeth_job_double_main.zig",
        .symptom = "J5",
        .canary_seeds = 40,
    },
    .{
        .name = "job_rewrite",
        .root = "src/sim_c1_teeth_job_rewrite_main.zig",
        .symptom = "J3",
        .canary_seeds = 40,
        .plain_symptom = "J4",
    },
    .{
        .name = "job_cancel",
        .root = "src/sim_c1_teeth_job_cancel_main.zig",
        .symptom = "J6",
        .canary_seeds = 80,
        .plain_symptom = "J6",
    },
    .{
        .name = "job_deadline",
        .root = "src/sim_c1_teeth_job_deadline_main.zig",
        .symptom = job_deadline_symptom,
        .canary_seeds = 50,
        .plain_symptom = job_deadline_symptom,
    },
    .{
        .name = "job_deadline_late",
        .root = "src/sim_c1_teeth_job_deadline_late_main.zig",
        .symptom = job_deadline_symptom,
        .canary_seeds = 50,
        .plain_symptom = job_deadline_symptom,
    },
    .{
        .name = "job_deadline_offline",
        .root = "src/sim_c1_teeth_job_deadline_offline_main.zig",
        .symptom = job_deadline_symptom,
        .canary_seeds = 80,
        .seeds = 40,
        .plain_symptom = job_deadline_symptom,
        .plain_seeds = 40,
    },
    .{
        .name = "job_gap",
        .root = "src/sim_c1_teeth_job_gap_main.zig",
        .symptom = "J4",
        .canary_seeds = 50,
        .plain_symptom = "J4",
    },
    .{
        .name = "job_stale",
        .root = "src/sim_c1_teeth_job_stale_main.zig",
        .symptom = "J9",
        .canary_seeds = 80,
        .plain_symptom = "J10",
    },
    .{
        .name = "job_refused_loop",
        .root = "src/sim_c1_teeth_job_refused_loop_main.zig",
        .symptom = "J10: an agent kept making",
        .canary_seeds = 80,
        .plain_symptom = "J10: an agent kept making",
    },
    .{
        .name = "job_unclaimed",
        .root = "src/sim_c1_teeth_job_unclaimed_main.zig",
        .symptom = "J8: a run that no node started",
        .canary_seeds = 60,
        .plain_symptom = "J8: a run that no node started",
    },
    .{
        .name = "job_wipe",
        .root = "src/sim_c1_teeth_job_wipe_main.zig",
        // J2 (a run id started again) or J7 (started under another tenure than its claim) and no
        // other check: `|` separates the two alternatives (`src/symptom.zig`).
        .symptom = job_wipe_symptom,
        .canary_seeds = 300,
        .seeds = 100,
        .plain_symptom = job_wipe_symptom,
        .plain_seeds = 100,
    },
    .{
        .name = "job_ledger_small",
        .root = "src/sim_c1_teeth_job_ledger_small_main.zig",
        .symptom = "J8: the start ledger is full (16 runs)",
        // A fixed range at 400 operations, not fresh seeds at drawn ones (#236): the drawn
        // operations (52 to 329 in the ten seeds of the miss) start 9 to 16 runs, which never
        // fill a ledger of 16. At 400 operations 8 of seeds 1..10 fail, so 15 seeds miss a
        // working check with probability 0.2^15 = 3e-11.
        .canary_seeds = 15,
        .canary_first = 1,
        .plain_symptom = "J8: the start ledger is full (16 runs)",
        .ops = 400,
    },
    .{
        .name = "relay_leak",
        .root = "src/sim_c1_teeth_relay_leak_main.zig",
        // R1 (a listener open on a stopped container); relayed jobs exist only in the strong
        // world, which the tooth switches on. Plain runs (no `--c1`) judge R1 too.
        .symptom = "R1",
        .canary_seeds = 20,
        .plain_symptom = "R1",
    },
    .{
        .name = "relay_dropped",
        .root = "src/sim_c1_teeth_relay_dropped_main.zig",
        // R3 (a started job's spec lacks its relay); relayed jobs exist only in the strong world,
        // which the tooth switches on. Plain runs (no `--c1`) judge R3 too.
        .symptom = "R3",
        .canary_seeds = 20,
        .plain_symptom = "R3",
    },
    .{
        .name = "job_reuse",
        .root = "src/sim_c1_teeth_job_reuse_main.zig",
        // J11 (a run that exited without a node starting it); the reuse world
        // exists only with the tooth or `sim-c1-reuse`. Plain runs judge J11 too.
        .symptom = "J11",
        .canary_seeds = 60,
        .plain_symptom = "J11",
        .ops = 300,
    },
    .{
        .name = "job_evicted",
        .root = "src/sim_c1_teeth_job_evicted_main.zig",
        // With #202 fixed (agents arm a run's deadline when it starts), the second clause is hit
        // by about one seed in a hundred: seed 32 until B2.1 slice 6 (#205: a failing step no
        // longer aborts the pass) shifted the world, then seed 186 (1..2000 searched up to the
        // first hit; docs/decisions/2026-11-11-job-evicted-tooth-sparse.md), then seed 241 after
        // #225's fix (docs/decisions/2026-11-13-job-evicted-tooth-seed-241.md). CI's run ends
        // there, and the fleet canary runs seed 241 alone at 300 operations (fresh seeds at
        // drawn operations would take hours for a one-in-a-hundred hit). A sparse tooth:
        // widening its world so more seeds hit is B3 work. Seed 241 passes with the fault off.
        .symptom = "J8: a run that no node started",
        .canary_seeds = 1,
        .canary_first = 241,
        .first_seed = 241,
        .seeds = 241,
        .ops = 300,
    },
    .{
        .name = "job_pass_break",
        .root = "src/sim_c1_teeth_job_pass_break_main.zig",
        .symptom = "J6",
        // Sparse: seeds 225 and 44 of the evict world are its known hits (J6 at 21,596 and
        // 23,406 ms on the loop's `break`); seeds 1..40 have none. The unit tests in
        // `agent_jobs_test.zig` (#247) are the real guard of both halves of the fix.
        .canary_seeds = 1,
        .canary_first = 225,
        .also_seeds = &.{44},
        .first_seed = 225,
        .seeds = 225,
        .ops = 300,
    },
};

/// The fleet's canary runs of the two runners outside `c1_teeth_roots` (see there).
const canary_seeds_teeth = 10;
const job_deadline_symptom = "J8: a run kept executing past its deadline|" ++
    "J8: a run is still open long after its deadline";
const job_wipe_symptom = "J2: a run id was started a second time|" ++
    "J7: a run was started under another tenure";
const canary_seeds_swarm_teeth = 200;
/// What a failure of each of the two must start with: the check their fault breaks (the text
/// `sim_teeth` and `sim_swarm_teeth` print, measured 2026-11-05), so a canary that fails some
/// other way is a wrong symptom, not a catch.
const canary_symptom_teeth = "a container runs on a node whose lease ran out longer ago than " ++
    "the lost grace";
const canary_symptom_swarm_teeth = "a chunk with wrong bytes was accepted";

/// `zig build sim-c1 [-Dseed=N] [-Dops=N] [-Dnodes=N]`: the cluster simulation with the
/// per-revision invariant checks (`Options.c1`), natively and as WebAssembly, the reports
/// compared byte for byte. `sim-c1-exe` installs the native runner (`sim_cluster --c1`);
/// `sim-c1-teeth` runs the 23 negative tests, each of which passes only if its check fires.
fn add_sim_c1_steps(b: *std.Build, sim: SimStepOptions) void {
    const exe = b.addExecutable(.{
        .name = "sim_cluster",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_cluster_main.zig"),
            .target = sim.target,
            .optimize = sim.optimize,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    b.step("sim-c1-exe", "Install the native sim-c1 runner (sim_cluster --c1)")
        .dependOn(&install.step);
    const nodes = b.option(u32, "c1-nodes", "Nodes of sim-c1 (default: the seed picks)") orelse 0;
    const seed_text = b.fmt("{d}", .{sim.seed orelse 1});
    const ops_text = ops_argument(b, sim);
    const nodes_text = b.fmt("{d}", .{if (sim.auto_shape) 0 else nodes});
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{ seed_text, ops_text, nodes_text, "--c1" });
    run.addArg(b.fmt("--profile={s}", .{sim.profile}));
    const native_report = run.captureStdOut(.{});
    const step = b.step("sim-c1", "Run sim-c1 natively and as WASM, and compare (-Dseed=N)");
    for (v8_modes) |mode| {
        const node = b.addSystemCommand(&.{ "node", "--no-warnings", mode });
        node.addFileArg(b.path("tools/wasm_check.mjs"));
        node.addArg("--sim-c1");
        node.addFileArg(sim.library.getEmittedBin());
        node.addArgs(&.{ seed_text, ops_text, nodes_text, "true", sim.profile });
        node.addFileArg(native_report);
        step.dependOn(&node.step);
    }
    const teeth = b.step("sim-c1-teeth", "Run the sim-c1 negative tests; each must fire its check");
    const teeth_exes = b.step("sim-c1-teeth-exe", "Install the 24 fault-on sim-c1 runners");
    for (c1_teeth_roots) |entry| {
        const teeth_exe = b.addExecutable(.{
            .name = b.fmt("sim_c1_teeth_{s}", .{entry.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry.root),
                .target = sim.target,
                .optimize = .ReleaseSafe,
                .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
            }),
        });
        const teeth_run = b.addRunArtifact(teeth_exe);
        const seeds = b.fmt("{d}..{d}", .{ entry.first_seed, entry.seeds });
        const symptom = b.fmt("--expect-symptom={s}", .{entry.symptom});
        teeth_run.addArgs(&.{
            "--seeds",                  seeds,
            b.fmt("{d}", .{entry.ops}), "--c1",
            "--expect-fail",            symptom,
        });
        if (entry.any_symptom) teeth_run.addArg("--expect-symptom-any");
        teeth.dependOn(&teeth_run.step);
        const own = b.step(b.fmt("sim-c1-teeth-{s}", .{entry.name}), "One sim-c1 negative test");
        own.dependOn(&teeth_run.step);
        add_also_seeds(b, &.{ teeth, own }, teeth_exe, entry);
        add_plain_tooth(b, teeth, teeth_exe, entry);
        const own_install = b.addInstallArtifact(teeth_exe, .{});
        own.dependOn(&own_install.step);
        teeth_exes.dependOn(&own_install.step);
    }
    add_offline_step(b, sim);
    add_burst_step(b, sim);
    add_worlds_step(b, sim);
    add_reuse_step(b, sim);
    add_regress_step(b, sim);
    add_regressions_step(b, sim);
    add_fencing_teeth_step(b, sim);
}

/// Each more known hit of a sparse tooth (`also_seeds`), run alone with `--c1`: it must fail
/// with the tooth's symptom.
fn add_also_seeds(
    b: *std.Build,
    steps: []const *std.Build.Step,
    exe: *std.Build.Step.Compile,
    entry: anytype,
) void {
    for (entry.also_seeds) |seed| {
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{
            "--seeds",                  b.fmt("{d}..{d}", .{ seed, seed }),
            b.fmt("{d}", .{entry.ops}), "--c1",
            "--expect-fail",            b.fmt("--expect-symptom={s}", .{entry.symptom}),
        });
        for (steps) |step| step.dependOn(&run.step);
    }
}

/// The same fault in a plain run (no `--c1`): the job checks need no per-revision tap.
fn add_plain_tooth(
    b: *std.Build,
    teeth: *std.Build.Step,
    exe: *std.Build.Step.Compile,
    entry: anytype,
) void {
    const symptom = entry.plain_symptom orelse return;
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{
        "--seeds",                                 b.fmt("1..{d}", .{entry.plain_seeds}),
        b.fmt("{d}", .{entry.ops}),                "--expect-fail",
        b.fmt("--expect-symptom={s}", .{symptom}),
    });
    teeth.dependOn(&run.step);
}

/// `zig build sim-c1-regress`: replays `regress_replays` with the shipped code (ReleaseSafe).
fn add_regress_step(b: *std.Build, sim: SimStepOptions) void {
    const regress_help = "Replay the seeds of the sim-fleet issues of B2 slice 1";
    const regress = b.step("sim-c1-regress", regress_help);
    // ReleaseSafe, as `sim-c1-regressions` does: some replays run 250 to 508 operations,
    // and in Debug the step ran for hours (#171 review).
    const regress_exe = b.addExecutable(.{
        .name = "sim_c1_regress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_cluster_main.zig"),
            .target = sim.target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    for (regress_replays) |line| {
        const replay = b.addRunArtifact(regress_exe);
        replay.addArgs(line);
        regress.dependOn(&replay.step);
    }
}

/// The replay lines of B2 slice 1; each must pass (`sim-c1-regress`, ReleaseSafe).
/// - The first six fail on main a864e89 (before the sim node clock's `spend_until` and the
///   restart rule) and pass here: the newest fleet lines of #135 (J8), #143 (J6), #151 (J8),
///   #136 (I1b), #166 (J8) and #176 (J8). A change that brings back the step overrun fails them.
/// - The original lines of #151, #142, #143, #135 and #137 pass on a864e89 too: smoke.
/// - Seeds 31, 53 and 102 of the 2,000-seed sweep fail J8 without the J8 true start.
/// - 1612 and 1384 are the I1b/I3 failures of #159's review (a restart that read a node
///   clock ahead of true time), plain and under C1.
const regress_replays = [_][]const []const u8{
    &.{
        "2072606796",
        "11",
        "2",
        "--profile=partitions",
        "--lease-ttl-ms=9210",
        "--replicas-pct=100",
        "--heal-at=219",
    },
    &.{
        "2461711096",
        "205",
        "9",
        "--profile=partitions",
        "--lease-ttl-ms=9285",
        "--replicas-pct=300",
        "--heal-at=543",
    },
    &.{
        "1806894768",
        "61",
        "1",
        "--c1",
        "--profile=slow_store",
        "--lease-ttl-ms=10000",
        "--replicas-pct=100",
        "--heal-at=130",
    },
    &.{
        "726793278",
        "29",
        "11",
        "--c1",
        "--profile=partitions",
        "--lease-ttl-ms=8799",
        "--replicas-pct=200",
        "--heal-at=355",
    },
    &.{
        "1097",
        "100",
        "0",
        "--c1",
        "--heal-at=93",
    },
    &.{
        "2646538718",
        "59",
        "4",
        "--c1",
        "--profile=partitions",
        "--lease-ttl-ms=10000",
        "--replicas-pct=100",
        "--heal-at=61",
    },
    &.{
        "780935350",
        "121",
        "3",
        "--c1",
        "--lease-ttl-ms=9528",
        "--replicas-pct=200",
        "--heal-at=193",
    },
    &.{
        "316526503",
        "132",
        "3",
        "--c1",
        "--lease-ttl-ms=9925",
        "--replicas-pct=300",
        "--heal-at=470",
    },
    &.{
        "1784779402",
        "134",
        "2",
        "--profile=slow_store",
        "--lease-ttl-ms=9132",
        "--replicas-pct=200",
        "--heal-at=158",
    },
    &.{
        "658857015",
        "17",
        "1",
        "--profile=partitions",
        "--lease-ttl-ms=9000",
        "--replicas-pct=100",
        "--heal-at=41",
    },
    &.{
        "1594217185",
        "263",
        "4",
        "--lease-ttl-ms=9731",
        "--replicas-pct=300",
        "--heal-at=270",
    },
    &.{
        "31",
        "508",
        "8",
        "--profile=slow_store",
        "--lease-ttl-ms=9669",
        "--replicas-pct=300",
        "--heal-at=262",
    },
    &.{
        "53",
        "247",
        "4",
        "--lease-ttl-ms=9393",
        "--replicas-pct=300",
        "--heal-at=152",
    },
    &.{
        "102",
        "112",
        "1",
        "--profile=slow_store",
        "--lease-ttl-ms=10000",
        "--replicas-pct=100",
        "--heal-at=99",
    },
    // The I1b/I3 failures of #159's review (a restart that read a node clock ahead of true
    // time): seeds 1384 and 1612, plain and under C1. Seed 893 (625 operations, 8 nodes; about
    // 6 minutes a replay in ReleaseSafe) is in `c1_regressions` and not here: its plain line
    // runs in `sim-c1-regressions`; its `--c1` line (the agent's refused re-reports) was cut
    // from CI for time and is covered by the agent's unit test and the sweeps.
    &.{
        "1612",                 "351",
        "2",                    "--c1",
        "--lease-ttl-ms=10000", "--replicas-pct=100",
        "--heal-at=218",
    },
    &.{ "1384", "198", "10", "--lease-ttl-ms=10000", "--replicas-pct=100", "--heal-at=139" },
    &.{
        "1384",
        "198",
        "10",
        "--c1",
        "--lease-ttl-ms=10000",
        "--replicas-pct=100",
        "--heal-at=139",
    },
};

/// Seeds of `sim-c1-offline`; about 45 s.
const offline_seeds_max = 30;

/// Seed ranges of `sim-c1-burst`, one process each so the build runs them in parallel: seed 2 at
/// 300 operations failed J8 on a correct agent (#198) when the simulator's record of job starts
/// was too short, and seeds 14 and 17 when the agent left a run started late in a step with no
/// deadline wake (#202); seed 21 caught the first form of that fix. A seed takes about 165 s
/// alone (measured), so 1..20 (about 55 CPU minutes) does not fit CI's budget: the seeds that
/// once failed run, one process each. Seeds 1..60 were swept by hand for #202 (0 of 60 failed).
const burst_seed_ranges = [_][]const u8{ "1..2", "14..14", "17..17", "21..21" };

/// `zig build sim-c1-burst`: the burst world (one node, bursts of 12 short jobs; #198) with the
/// agent right: no seed may fail. With `Node.started_true` back at 8 entries seed 2 fails J8.
fn add_burst_step(b: *std.Build, sim: SimStepOptions) void {
    const exe = b.addExecutable(.{
        .name = "sim_c1_burst",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_c1_burst_world_main.zig"),
            .target = sim.target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    const step = b.step("sim-c1-burst", "Run sim-c1 in the burst world (#198, #202): J8 must hold");
    for (burst_seed_ranges) |range| {
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ "--seeds", range, "300", "--c1" });
        run.expectExitCode(0);
        step.dependOn(&run.step);
    }
}

/// The roots of `sim-c1-worlds`: the world of the `job_evicted` tooth, fix on.
const worlds = [_][]const u8{
    "src/sim_c1_evict_world_main.zig",
};

/// `zig build sim-c1-worlds`: the positive runs of those worlds; no seed of 1 to 5, nor seed 225
/// (#248), may fail.
fn add_worlds_step(b: *std.Build, sim: SimStepOptions) void {
    const step = b.step("sim-c1-worlds", "Run sim-c1 in the job_evicted world");
    const only = b.step("sim-c1-worlds-exe", "Install the world runners");
    for (worlds) |root| {
        const exe = b.addExecutable(.{
            .name = std.fs.path.stem(root),
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = sim.target,
                .optimize = .ReleaseSafe,
                .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
            }),
        });
        only.dependOn(&b.addInstallArtifact(exe, .{}).step);
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ "--seeds", "1..5", "300", "--c1" });
        run.expectExitCode(0);
        step.dependOn(&run.step);
        // #248: seed 225 broke J6 on fb385b2 (a server failure ended the job pass before an
        // orphan's committed stop); the replay must pass.
        const replay = b.addRunArtifact(exe);
        replay.addArgs(&.{ "225", "300", "1", "--c1" });
        replay.expectExitCode(0);
        step.dependOn(&replay.step);
    }
}

/// The seeds of `sim-c1-reuse` (B2.1 slice 4): the hit rate of the reuse world is measured over
/// them (docs/decisions/2026-11-11-job-reuse-tooth.md).
const reuse_seeds_max = 60;

/// `zig build sim-c1-reuse`: the world of the `job_reuse` tooth with the agent right; no seed of
/// 1 to `reuse_seeds_max` may fail. `sim-c1-reuse-exe` installs the runner.
fn add_reuse_step(b: *std.Build, sim: SimStepOptions) void {
    const exe = b.addExecutable(.{
        .name = "sim_c1_reuse_world",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_c1_reuse_world_main.zig"),
            .target = sim.target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    b.step("sim-c1-reuse-exe", "Install the reuse world's runner")
        .dependOn(&b.addInstallArtifact(exe, .{}).step);
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{ "--seeds", b.fmt("1..{d}", .{reuse_seeds_max}), "300", "--c1" });
    run.expectExitCode(0);
    b.step("sim-c1-reuse", "Run sim-c1 in the job_reuse world with the agent right (J11 holds)")
        .dependOn(&run.step);
}

/// `zig build sim-c1-offline`: the positive run of the `job_deadline_offline` tooth's world (long
/// cuts, short deadlines) with the fix on. It passes only if no seed fails (J8 and the rest).
fn add_offline_step(b: *std.Build, sim: SimStepOptions) void {
    const exe = b.addExecutable(.{
        .name = "sim_c1_offline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_c1_offline_main.zig"),
            .target = sim.target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{
        "--seeds",                            b.fmt("1..{d}", .{offline_seeds_max}),
        b.fmt("{d}", .{c1_teeth_operations}), "--c1",
    });
    b.step("sim-c1-offline", "Run sim-c1 in the offline-deadline world with the fix on (J8 holds)")
        .dependOn(&run.step);
}

/// Replays of sim-c1 runs that once failed, each a fixed command line; each must pass.
const c1_regressions = [_][]const []const u8{
    // B2 re-review: before the fix the agent re-reported runs the store refused on every pass,
    // and a step 31 ms before a deadline ran 4.7 s, past J8's bound. The run the review named
    // was `240 798 2 ... --heal-at=487` (43 s); 310 operations fail the same way in 8 s.
    &.{ "240", "310", "2", "--c1", "--lease-ttl-ms=10000", "--replicas-pct=200", "--heal-at=487" },
    // B2 hardening (#171) after #159's node clock: seed 1612 fenced late when a crash landed
    // inside a step's spent time (a simulator artefact), and seed 893 kept refusing the report
    // of a container that had ended under an older assignment (an agent bug).
    &.{ "1612", "351", "2", "--lease-ttl-ms=10000", "--replicas-pct=100", "--heal-at=218" },
    &.{ "893", "625", "8", "--lease-ttl-ms=10000", "--replicas-pct=300", "--heal-at=584" },
    // #142 reopened (J6 seed 102): the call floor was one budget per step, so a slow store and
    // short-grace runs starved every read and the committed stop was never seen. The floor is
    // per call now (`Agent.before_call`); the stop is read within 2.7 s.
    &.{
        "102",                  "112",                "1",
        "--c1",                 "--strong",           "--profile=slow_store",
        "--lease-ttl-ms=10000", "--replicas-pct=100", "--heal-at=99",
    },
    // #225: an agent that fenced after a restart waited with a watch that answered at once (no
    // replica list, so no revision to watch from), and stepped in a hot loop until the fence
    // ended: 52 steps in one millisecond. A wait while fencing is a pause now (`Wakeup.watch`).
    &.{
        "9739923",            "114",                   "4",
        "--strong",           "--profile=crash_heavy", "--lease-ttl-ms=10000",
        "--replicas-pct=200", "--heal-at=104",
    },
    &.{
        "2764708423",         "69",                    "4",
        "--strong",           "--profile=crash_heavy", "--lease-ttl-ms=8248",
        "--replicas-pct=300", "--heal-at=58",
    },
    // #247: a lost answer (ZC-E0201) to a run's write ended the job pass, and a run whose
    // cancel had committed kept running past J6's bound (137,767 ms) on f49041a. It records the
    // issue and guards nothing: fb385b2 passes it by luck of timing, and so does the loop's
    // `break` put back. The guards are the #247 unit tests (`agent_jobs_test.zig`) and the
    // `job_pass_break` tooth (docs/decisions/2026-11-14-b3-soak-after-247.md).
    &.{
        "870682998",          "80",                   "3",
        "--strong",           "--profile=slow_store", "--lease-ttl-ms=8488",
        "--replicas-pct=100", "--heal-at=76",
    },
    // #96: an agent stepped in a busy loop in the fault phase (2,098 steps) on f49041a; #244's
    // fence pause (`.watch = false`) fixed it on fb385b2 (1,492 steps).
    &.{
        "833885280",           "185",                "4",
        "--c1",                "--strong",           "--profile=crash_heavy",
        "--lease-ttl-ms=8226", "--replicas-pct=200", "--heal-at=390",
    },
};

/// `zig build sim-c1-regressions`: replays `c1_regressions` with the shipped code (ReleaseSafe).
fn add_regressions_step(b: *std.Build, sim: SimStepOptions) void {
    const exe = b.addExecutable(.{
        .name = "sim_c1_regressions",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_cluster_main.zig"),
            .target = sim.target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    const help = "Replay sim-c1 runs that once failed; each must pass";
    const step = b.step("sim-c1-regressions", help);
    for (c1_regressions) |args| {
        const run = b.addRunArtifact(exe);
        run.addArgs(args);
        run.expectExitCode(0);
        step.dependOn(&run.step);
    }
}

/// `zig build sim-fencing-teeth`: the negative test of `fencing_settles`. The simulator with
/// the old `ttl / 3` renewal rule and the shortest-ttl bound lifted, at a ttl of 4,000 ms (the
/// server refuses it now), must fail with that check's symptom. Not in `c1_teeth_roots`: the
/// fleet's canary draws no ttl by hand. Seeds 2..4: seed 1's fence loop is caught first by
/// `converged` since fence waits became pauses (docs/decisions/2026-11-13-fencing-teeth-seeds.md).
fn add_fencing_teeth_step(b: *std.Build, sim: SimStepOptions) void {
    const exe = b.addExecutable(.{
        .name = "sim_c1_teeth_oldrule",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_c1_teeth_oldrule_main.zig"),
            .target = sim.target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{
        "--seeds",                              "2..4",                "100",
        "1",                                    "--lease-ttl-ms=4000", "--expect-fail",
        "--expect-symptom=agents kept fencing",
    });
    const help = "Run the simulator with the old renewal rule at ttl 4000; it must fail";
    b.step("sim-fencing-teeth", help).dependOn(&run.step);
}

const c1_teeth_operations = 100;

/// `zig build sim-swarm [-Dseed=N] [-Dops=N]`: the swarm simulation (src/sim_swarm.zig), run
/// natively and as WebAssembly for the same seed, and the two reports compared byte for byte.
fn add_sim_swarm_step(b: *std.Build, sim: SimStepOptions) void {
    const exe = b.addExecutable(.{
        .name = "sim_swarm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_swarm_main.zig"),
            .target = sim.target,
            .optimize = sim.optimize,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    const exe_help = "Install the native sim-swarm runner into zig-out/bin";
    b.step("sim-swarm-exe", exe_help).dependOn(&install.step);
    const seed_text = b.fmt("{d}", .{sim.seed orelse 1});
    const ops_text = ops_argument(b, sim);
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{ seed_text, ops_text });
    run.addArg(b.fmt("--profile={s}", .{sim.swarm_profile}));
    const native_report = run.captureStdOut(.{});
    const help = "Run the swarm simulation natively and as WASM, and compare (-Dseed=N)";
    const step = b.step("sim-swarm", help);
    for (v8_modes) |mode| {
        const node = b.addSystemCommand(&.{ "node", "--no-warnings", mode });
        node.addFileArg(b.path("tools/wasm_check.mjs"));
        node.addArg("--sim-swarm");
        node.addFileArg(sim.library.getEmittedBin());
        node.addArgs(&.{ seed_text, ops_text, sim.swarm_profile });
        node.addFileArg(native_report);
        step.dependOn(&node.step);
    }
}

/// `zig build sim-swarm-teeth`: the swarm simulator built with the fetch plan accepting chunks
/// without checking them (`src/sim_swarm_teeth_main.zig`, the only root that can switch it on),
/// run over seeds 1 to `teeth_seeds_max`; it passes only if at least one seed fails.
fn add_sim_swarm_teeth_step(b: *std.Build, sim: SimStepOptions) void {
    const exe = b.addExecutable(.{
        .name = "sim_swarm_teeth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_swarm_teeth_main.zig"),
            .target = sim.target,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    b.step("sim-swarm-teeth-exe", "Install the fault-on swarm runner (test-only)")
        .dependOn(&install.step);
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{
        "--seeds",                         b.fmt("1..{d}", .{teeth_seeds_max}),
        b.fmt("{d}", .{teeth_operations}), "--expect-fail",
    });
    const help = b.fmt("Run the swarm simulator with the fetch plan's test-only fault on; it " ++
        "must fail within {d} seeds", .{teeth_seeds_max});
    b.step("sim-swarm-teeth", help).dependOn(&run.step);
}

/// `zig build sim-fleet-exe` installs `zig-out/bin/sim_fleet`, the reporter of the simulation fleet
/// (ops/sim-fleet/README.md): it files the failures `sim_cluster` finds. A host tool with no
/// dependency; its tests run in `zig build test`.
fn add_sim_fleet_step(b: *std.Build, sim: SimStepOptions) void {
    const exe = b.addExecutable(.{
        .name = "sim_fleet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_fleet.zig"),
            .target = sim.target,
            .optimize = sim.optimize,
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    b.step("sim-fleet-exe", "Install the simulation fleet's reporter into zig-out/bin")
        .dependOn(&install.step);
    // `zig build test` also runs the fleet's own shell functions against this reporter:
    // `run.sh`'s crash records and its canary, the latter over the manifest `sim-canary-exe`
    // installs.
    const test_step = &b.top_level_steps.get("test").?.step;
    const records = b.addSystemCommand(&.{"sh"});
    records.addFileArg(b.path("ops/sim-fleet/test-crash-record.sh"));
    records.addArtifactArg(exe);
    records.addFileInput(b.path("ops/sim-fleet/run.sh"));
    records.expectExitCode(0);
    test_step.dependOn(&records.step);
    const canary = b.addSystemCommand(&.{"sh"});
    canary.addFileArg(b.path("ops/sim-fleet/test-canary.sh"));
    canary.addArtifactArg(exe);
    canary.addFileArg(b.addWriteFiles().add("canaries.txt", canary_manifest(b)));
    canary.addFileInput(b.path("ops/sim-fleet/run.sh"));
    canary.expectExitCode(0);
    test_step.dependOn(&canary.step);
    // demo-b3's guest script reads the relay logs of the Zigbox runtime's layout and fails on none.
    const guest = b.addSystemCommand(&.{"sh"});
    guest.addFileArg(b.path("ops/demo-b3/test-guest.sh"));
    guest.addFileInput(b.path("ops/demo-b3/guest.sh"));
    guest.expectExitCode(0);
    test_step.dependOn(&guest.step);
}

/// The seeds the teeth test runs and the most the simulator may need to catch the agent's
/// test-only fault (docs/core.md, "The cluster simulation"): `sim-teeth` fails if none of them
/// fails. The fault is caught by the first seed or two; the margin is for a change of the model.
const teeth_seeds_max = 10;
const teeth_operations = 100;

/// `zig build sim-teeth`: the cluster simulator built with the agent ignoring every stop order
/// (`src/sim_teeth_main.zig`, the only root that can switch it on), run over seeds 1 to
/// `teeth_seeds_max`; it passes only if at least one seed fails. Run by `check`, not by `test`:
/// it compiles the simulator a second time (in Debug, which compiles in seconds and runs seed 1
/// in about a second). The executable is run, never installed.
fn add_sim_teeth_step(b: *std.Build, sim: SimStepOptions) void {
    const exe = b.addExecutable(.{
        .name = "sim_teeth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_teeth_main.zig"),
            .target = sim.target,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zigbox", .module = sim.zigbox }},
        }),
    });
    // For shrinking the fault's failures by hand (`sim_teeth --seeds 1..3 100 --shrink`); only
    // this named step installs it, so `zig build` never puts it in zig-out.
    const install = b.addInstallArtifact(exe, .{});
    b.step("sim-teeth-exe", "Install the fault-on simulator runner (test-only)")
        .dependOn(&install.step);
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{
        "--seeds",                         b.fmt("1..{d}", .{teeth_seeds_max}),
        b.fmt("{d}", .{teeth_operations}), "--expect-fail",
    });
    const help = b.fmt("Run the cluster simulator with the agent's test-only fault on; it must " ++
        "fail within {d} seeds", .{teeth_seeds_max});
    b.step("sim-teeth", help).dependOn(&run.step);
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
    const pulls = b.addSystemCommand(&.{ "node", "--no-warnings" });
    pulls.addFileArg(b.path("tools/pulls_check.mjs"));
    step.dependOn(&pulls.step);
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

/// `zig build check`: every gate a slice must pass, in one command, ending in the one line a
/// report quotes (`check: PASS <commit>`). The cheap gates run first, as dependencies; then the
/// tool (src/testing/check.zig) runs what a dependency cannot express: the Postgres conformance
/// suite when `ZCUBE_TEST_POSTGRES` is set, `sim-c0` with a fresh seed, and, as root,
/// `zig build test` again as -Dcheck-user (default tester) in a scratch worktree, because CI runs
/// as an ordinary user. -Dcheck-user=- skips that. Not in `check`: `agent-smoke` and `demo-c0`
/// (CI runs them; they are slow and start servers).
fn add_check_step(b: *std.Build) void {
    const user = b.option([]const u8, "check-user", "User for the non-root test run, or -") orelse
        "tester";
    const tool = b.addExecutable(.{
        .name = "check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/check.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.setCwd(b.path("."));
    run.addArgs(&.{ b.graph.zig_exe, user });
    run.has_side_effects = true;
    const gates = [_][]const u8{
        "install",            "test",       "tidy",          "errors-site-check",
        "wasm-check",         "wasm-test",  "console-wasm",  "check-store-memory",
        "check-store-sqlite", "mtls-teeth", "demo-b3-build",
    };
    for (gates) |name| {
        const gate = b.top_level_steps.get(name) orelse @panic(name);
        run.step.dependOn(&gate.step);
    }
    const step = b.step("check", "Every gate, then the test suite as a non-root user; one line");
    step.dependOn(&run.step);
}
