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
//! **The remembered pair.** The pair the server's answers carried (`agent_client.zig`, "Nothing
//! from behind") is loaded from the state directory at start and saved after every step, at most
//! every `verified_save_ms`, and once more at a clean stop. A save that fails is shown once
//! (`ZC-E0216`) and retried; the agent runs on, since a file that lags is only weaker. A pair
//! saved for another `--server`, or a server that keeps no pair (a memory store), is a line of
//! news on stdout, and the agent runs on without that pair.
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
const diag_mod = @import("diag.zig");
const fake_runtime = @import("fake_runtime.zig");
const loop_mod = @import("agent_loop.zig");
const remote_mod = @import("agent_remote.zig");
const BoundedArena = @import("server_arena.zig").BoundedArena;
const failures = @import("store_failures.zig");
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
    policy: loop_mod.Loop,
    /// The last save of the remembered pair failed; shown once, cleared by one that works.
    save_failed: bool = false,

    /// One step of the core, with what the policy says to tell the person.
    fn pass(shell: *Shell) loop_mod.Outcome {
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
        const result = shell.agent.reconcile(&ctx);
        shell.save_pair(false);
        shell.notice_pair();
        const wake = result catch {
            const outcome: loop_mod.Outcome = .{ .failed = shell.diag.code };
            const report = shell.policy.step_done(shell.clock.now_ms(), outcome);
            if (report == .failure) shell.report_failure();
            return outcome;
        };
        const outcome: loop_mod.Outcome = .{ .ok = wake };
        const report = shell.policy.step_done(shell.clock.now_ms(), outcome);
        if (report == .recovered) shell.recovered();
        shell.notice_lease(before);
        return outcome;
    }

    /// Holds up to `slice_ms` for a replica change or a container event. True if one came, or the
    /// watch failed (the next pass reports and retries).
    fn watch(shell: *Shell, slice_ms: u32) bool {
        shell.diag.reset();
        const changed = shell.remote.watch_once(slice_ms, &shell.diag) catch return true;
        shell.notice_pair();
        if (changed) return true;
        shell.arena.reset();
        const events = shell.fake.interface().events(shell.arena.allocator(), 0, &shell.diag) catch
            return true;
        return events.len > 0;
    }

    /// Saves the pair if it is due; `final` (a clean stop) saves it whatever the time.
    fn save_pair(shell: *Shell, final: bool) void {
        const state = shell.fake.state.interface();
        const now_ms = shell.clock.now_ms();
        const saved = if (final)
            shell.remote.save_final(state, now_ms)
        else
            shell.remote.save(state, now_ms);
        saved catch |err| {
            if (shell.save_failed) return;
            shell.save_failed = true;
            var warning: Diag = undefined;
            warning.reset();
            var buffer: [constants.state_path_bytes_max + 16]u8 = undefined;
            const path = shell.remote.remembered_path(&buffer);
            _ = failures.remembered_unusable(&warning, path, "write", @errorName(err)) catch {};
            shell.show("\n", &warning, "zcube-agent: running on; it will try again\n");
            return;
        };
        shell.save_failed = false;
    }

    /// News about the remembered pair, one line on stdout.
    fn notice_pair(shell: *Shell) void {
        const notice = shell.remote.take_notice() orelse return;
        var buffer: [512]u8 = undefined;
        const line = switch (notice) {
            .server_changed => std.fmt.bufPrint(
                &buffer,
                "zcube-agent: {s} was saved for server {s}, not {s}; starting fresh\n",
                .{
                    remote_mod.client.remembered_file,
                    shell.remote.previous_server_name(),
                    shell.remote.server,
                },
            ),
            .unverified => std.fmt.bufPrint(
                &buffer,
                "zcube-agent: the server keeps no revision for its store across restarts " ++
                    "(a memory store); this agent keeps none either\n",
                .{},
            ),
        } catch return;
        std.Io.File.stdout().writeStreamingAll(shell.io, line) catch {}; // Nowhere else to say it.
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
        const before = "\nzcube-agent: the agent could not finish a step\n";
        const after = "zcube-agent: retrying; containers keep running meanwhile\n";
        shell.show(before, &shell.diag, after);
    }

    fn recovered(shell: *Shell) void {
        std.Io.File.stderr().writeStreamingAll(
            shell.io,
            "zcube-agent: the agent is running again\n",
        ) catch {};
    }

    /// A lease that was replaced is ZC-W0501, and a first one is a line of news.
    fn notice_lease(shell: *Shell, before: store.LeaseId) void {
        const now = shell.agent.lease;
        const news = loop_mod.lease_news(before, now);
        if (news == .none) return;
        var buffer: [128]u8 = undefined;
        if (news == .registered) {
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
    var http_transport: remote_mod.HttpTransport = .{
        .client = .{ .io = io, .address = config.server },
    };
    var remote = remote_mod.RemoteStore.init(gpa, http_transport.transport(), config.node);
    var server_buffer: [remote_mod.client.remembered_server_bytes_max]u8 = undefined;
    // An IP address and a port always fit.
    const server = std.fmt.bufPrint(&server_buffer, "{f}", .{config.server}) catch unreachable;
    load_pair(gpa, &remote, fake, config.state_dir, server, &diag) catch
        return fail(io, &diag, config.verbose);
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
        .policy = loop_mod.Loop.init(),
    };
    defer shell.arena.deinit();
    announce(io, config);
    shell.notice_pair();
    install_signals();
    loop(&shell);
    shell.save_pair(true);
    return constants.exit_ok;
}

fn loop(shell: *Shell) void {
    while (true) {
        if (stop_requested.load(.acquire)) shell.policy.request_stop();
        switch (shell.policy.next(shell.clock.now_ms())) {
            .stop => return,
            .step => _ = shell.pass(),
            .pause_ms => |ms| shell.pause(ms),
            .watch_ms => |ms| shell.policy.watch_done(shell.watch(ms)),
        }
    }
}

fn load_pair(
    gpa: std.mem.Allocator,
    remote: *remote_mod.RemoteStore,
    fake: *fake_runtime.FakeRuntime,
    state_dir: []const u8,
    server: []const u8,
    diag: *Diag,
) error{BackendFailed}!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const state = fake.state.interface();
    return remote.load(state, state_dir, server, arena_state.allocator(), diag);
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
