//! The agent's loop: the shell half of the step model (docs/core.md), for the node. The core's
//! `Agent.reconcile` compares this node's desired replicas with what the runtime lists, starts and
//! stops containers and says what it saw; this file does what the core must not: it talks to the
//! server over HTTP (`agent_remote.zig`), runs the fake runtime (`fake_runtime.zig`), waits, reads
//! the clock and handles signals. Shell code, single-threaded: the agent never has a thread, so
//! nothing it does can race what it starts.
//!
//! **The wait.** After a step the agent waits until the core's `Wakeup.at_ms`, or a replica
//! changes (a long poll of the server, a quarter of a second at a time), or a container of this
//! node changes state (the runtime's events). A step that acted runs again at once, and the
//! second finds nothing to do: that is how the level-triggered core converges.
//!
//! **Failure shows once.** A server that cannot be reached, or a runtime that fails, is a
//! diagnostic on stderr when its code changes and every `server_report_ms` after that, and the
//! agent backs off (`server_retry_ms_min` doubling to `server_retry_ms_max`). Containers run on:
//! each is under a supervisor of its own. When the server returns, one line says so.
//!
//! **Stopping.** SIGINT or SIGTERM ends the loop. The containers are not stopped: that is what
//! lets a restarted agent adopt them, and an agent that loses its lease does the same in C0.

const std = @import("std");
const assert = std.debug.assert;
const agent_mod = @import("agent.zig");
const build_options = @import("build_options");
const clock_mod = @import("agent_clock.zig");
const config_mod = @import("agent_config.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const fake_runtime = @import("fake_runtime.zig");
const remote_mod = @import("agent_remote.zig");
const BoundedArena = @import("server_arena.zig").BoundedArena;
const store = @import("store.zig");

const Diag = diag_mod.Diag;

/// Set by the signal handler, read by the loop.
var stop_requested: std.atomic.Value(bool) = .init(false);

fn on_signal(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

fn install_signals() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = on_signal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

const Shell = struct {
    io: std.Io,
    clock: @import("clock.zig").Clock,
    remote: *remote_mod.RemoteStore,
    fake: *fake_runtime.FakeRuntime,
    agent: *agent_mod.Agent,
    arena: BoundedArena,
    diag: Diag,
    verbose: bool,
    // What was last reported, so that a server that stays down is shown once.
    last_code: ?@import("diag/codes.zig").Code = null,
    last_report_ms: u64 = 0,

    /// One step of the core. Null if it failed (the failure is reported).
    fn pass(shell: *Shell) ?controller.Wakeup {
        shell.arena.reset();
        shell.diag.reset();
        const ctx: agent_mod.Context = .{
            .store = shell.remote.interface(),
            .runtime = shell.fake.interface(),
            .clock = shell.clock,
            .arena = shell.arena.allocator(),
            .diag = &shell.diag,
        };
        const before = shell.agent.lease;
        const wake = shell.agent.reconcile(&ctx) catch {
            shell.report_failure();
            return null;
        };
        shell.recovered();
        shell.notice_lease(before);
        return wake;
    }

    /// Waits for the core's deadline, a replica change, or a container event; returns early on a
    /// stop request or a failure (the next pass reports and retries).
    fn wait(shell: *Shell, wake: controller.Wakeup) void {
        while (!stop_requested.load(.acquire)) {
            const now = shell.clock.now_ms();
            if (now >= wake.at_ms) return;
            const left = wake.at_ms - now;
            const slice: u32 = @intCast(@min(left, constants.agent_watch_slice_ms));
            shell.diag.reset();
            const changed = shell.remote.watch_once(slice, &shell.diag) catch return;
            if (changed) return;
            shell.arena.reset();
            const events = shell.fake.interface().events(
                shell.arena.allocator(),
                0,
                &shell.diag,
            ) catch
                return;
            if (events.len > 0) return;
        }
    }

    fn pause(shell: *Shell, ms: u32) void {
        // Slept in slices so that a stop request is noticed within one.
        var left = ms;
        while (left > 0) {
            if (stop_requested.load(.acquire)) return;
            const slice = @min(left, constants.server_poll_ms * 10);
            shell.io.sleep(.fromMilliseconds(slice), .awake) catch return;
            left -= slice;
        }
    }

    // ---- What the person running the agent sees ----

    fn report_failure(shell: *Shell) void {
        const code = shell.diag.code orelse return;
        const now = shell.clock.now_ms();
        if (shell.last_code == code) {
            if (now -| shell.last_report_ms < constants.server_report_ms) return;
        }
        shell.last_code = code;
        shell.last_report_ms = now;
        const before = "\nzcube-agent: the agent could not finish a step\n";
        const after = "zcube-agent: retrying; containers keep running meanwhile\n";
        shell.show(before, &shell.diag, after);
    }

    fn recovered(shell: *Shell) void {
        if (shell.last_code == null) return;
        shell.last_code = null;
        std.Io.File.stderr().writeStreamingAll(
            shell.io,
            "zcube-agent: the agent is running again\n",
        ) catch {};
    }

    /// A lease that was replaced is ZC-W0501, and a first one is a line of news.
    fn notice_lease(shell: *Shell, before: store.LeaseId) void {
        const now = shell.agent.lease;
        if (now == before) return;
        assert(now != store.lease_none);
        var buffer: [128]u8 = undefined;
        if (before == store.lease_none) {
            const text = "zcube-agent: node {s} registered on lease {d}\n";
            const line = std.fmt.bufPrint(&buffer, text, .{
                shell.agent.config.node, now,
            }) catch return;
            std.Io.File.stdout().writeStreamingAll(shell.io, line) catch {};
            return;
        }
        var warning: Diag = undefined;
        warning.reset();
        warning.raise(.W0501);
        warning.cause("lease {d} ended; node {s} registered again on lease {d}", .{
            before, shell.agent.config.node, now,
        });
        warning.fix(
            .{ .sentence = "if this repeats, check the network between the agent and the server" },
        );
        shell.show("\n", &warning, "zcube-agent: its containers were left running\n");
    }

    fn show(shell: *Shell, before: []const u8, diag: *const Diag, after: []const u8) void {
        var diagnostic: diag_mod.Diagnostic = undefined;
        diag_mod.to_diagnostic(&diagnostic, diag);
        var buffer: [constants.diag_output_bytes_max]u8 = undefined;
        const mode: @import("zigbox").render.Mode = if (shell.verbose) .verbose else .text;
        const text = diag_mod.render(&diagnostic, mode, false, &buffer);
        const file = std.Io.File.stderr();
        file.writeStreamingAll(shell.io, before) catch {}; // Nowhere else to report it.
        file.writeStreamingAll(shell.io, text) catch {};
        file.writeStreamingAll(shell.io, after) catch {};
    }
};

/// Runs the agent until it is told to stop. Returns the process's exit code.
pub fn run(init: std.process.Init, config: config_mod.Config) u8 {
    const io = init.io;
    const gpa = init.gpa;
    var diag: Diag = undefined;
    diag.reset();
    var exe_buffer: [constants.state_path_bytes_max]u8 = undefined;
    const exe_length = std.process.executablePath(io, &exe_buffer) catch
        return fail_start(io, &diag, config.verbose, "can't find its own executable");
    var real: clock_mod.RealClock = .{ .io = io };
    const fake = gpa.create(fake_runtime.FakeRuntime) catch return constants.exit_environment;
    defer gpa.destroy(fake);
    fake.init(io, real.clock(), .{
        .gpa = gpa,
        .state_dir = config.state_dir,
        .supervisor_exe = exe_buffer[0..exe_length],
        .fixtures = config.images,
    }, &diag) catch return fail(io, &diag, config.verbose);
    defer fake.deinit();
    var remote = remote_mod.RemoteStore.init(
        gpa,
        .{ .io = io, .address = config.server },
        config.node,
    );
    const agent = gpa.create(agent_mod.Agent) catch return constants.exit_environment;
    defer gpa.destroy(agent);
    agent.init(.{
        .node = config.node,
        .capacity = config.capacity,
        .address = config.address,
        .agent_version = build_options.version,
        .lease_ttl_ms = config.lease_ttl_ms,
    });
    var shell: Shell = .{
        .io = io,
        .clock = real.clock(),
        .remote = &remote,
        .fake = fake,
        .agent = agent,
        .arena = BoundedArena.init(gpa, constants.request_arena_bytes_max),
        .diag = undefined,
        .verbose = config.verbose,
    };
    defer shell.arena.deinit();
    announce(io, config);
    install_signals();
    loop(&shell);
    return constants.exit_ok;
}

fn loop(shell: *Shell) void {
    var retry_ms: u32 = constants.server_retry_ms_min;
    while (!stop_requested.load(.acquire)) {
        const wake = shell.pass() orelse {
            shell.pause(retry_ms);
            retry_ms = @min(retry_ms * 2, constants.server_retry_ms_max);
            continue;
        };
        retry_ms = constants.server_retry_ms_min;
        if (wake.acted > 0) continue;
        shell.wait(wake);
    }
}

fn announce(io: std.Io, config: config_mod.Config) void {
    var buffer: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "zcube-agent {s}: node {s}, server {f}, state {s}\n", .{
        build_options.version, config.node, config.server, config.state_dir,
    }) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {}; // Nowhere else to report it.
}

fn fail_start(io: std.Io, diag: *Diag, verbose: bool, what: []const u8) u8 {
    diag.reset();
    diag.raise(.E0506);
    diag.cause("{s}", .{what});
    diag.fix(.{ .sentence = "start the agent from its installed executable" });
    return fail(io, diag, verbose);
}

/// Prints the diagnostic and returns the exit code its blame decides.
pub fn fail(io: std.Io, diag: *const Diag, verbose: bool) u8 {
    assert(diag.code != null);
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const mode: @import("zigbox").render.Mode = if (verbose) .verbose else .text;
    const text = diag_mod.render(&diagnostic, mode, false, &buffer);
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to report it.
    return diag.exit_code();
}
