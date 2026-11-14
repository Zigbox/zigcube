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
const runtime_mod = @import("runtime.zig");
const zigbox = @import("zigbox");
const zigbox_runtime = @import("zigbox_runtime.zig");
const loop_mod = @import("agent_loop.zig");
const node_store = @import("node_store.zig");
const remote_mod = @import("agent_remote.zig");
const BoundedArena = @import("server_arena.zig").BoundedArena;
const agent_peer = @import("agent_peer.zig");
const api_tls_client = @import("api_tls_client.zig");
const dir_images = @import("dir_images.zig");
const zigbox_fetch = @import("zigbox_fetch.zig");
const peer_server_mod = @import("peer_server.zig");
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
    /// CLOCK_BOOTTIME: the clock of the fence.
    boot: @import("clock.zig").Clock,
    remote: *remote_mod.RemoteStore,
    runtime: runtime_mod.Runtime,
    /// The state directory as `AgentState`, for the remembered server pair.
    pair_state: *@import("fake_files.zig").DirState,
    state_dir: []const u8,
    agent: *agent_mod.Agent,
    arena: BoundedArena,
    diag: Diag,
    verbose: bool,
    policy: loop_mod.Loop,
    /// This boot's id, kept with the lease (`agent.Context.boot_id`).
    boot_id: []const u8,
    /// The image store whose summary the agent publishes; null for a runtime with none yet.
    images: ?node_store.Images = null,
    /// The last save of the remembered pair failed; shown once, cleared by one that works.
    save_failed: bool = false,
    /// The node's peer identity (docs/peer.md) and the transport its join calls use.
    peer: *agent_peer.Peer,
    peer_transport: remote_mod.client.Transport,
    /// The API's TLS client when `--ca` is given; it presents the new `node.crt` after a join.
    tls: ?*api_tls_client.Credentials = null,

    /// Joins the cluster CA or renews the credential when it is due. A failure never stops the
    /// agent: it is shown once per streak and tried again after `peer_join_retry_ms`.
    fn peer_step(shell: *Shell) void {
        const now_ms = shell.clock.now_ms();
        if (shell.remote.ca_key_id) |id| {
            if (shell.peer.observe_ca(id)) {
                shell.diag.reset();
                agent_peer.raise_ca_changed(&shell.diag, shell.agent.config.node);
                shell.show("\n", &shell.diag, "zcube-agent: joining the new CA\n");
                shell.diag.reset();
            }
        }
        // The server issues a credential only to a registered node (docs/api.md).
        const lease = shell.agent.lease;
        if (lease == store.lease_none or shell.agent.tenure == 0) return;
        if (!shell.peer.due(now_ms)) return;
        const timeout_ms = shell.before_fence(constants.peer_join_timeout_ms);
        if (timeout_ms == 0) return;
        shell.arena.reset();
        shell.diag.reset();
        const had = shell.peer.credential != null;
        const arena = shell.arena.allocator();
        shell.peer.step(shell.peer_transport, arena, lease, now_ms, timeout_ms, &shell.diag) catch {
            if (!shell.peer.reported) {
                shell.peer.reported = true;
                shell.show("\n", &shell.diag, "zcube-agent: running on; it will try again\n");
            }
            shell.diag.reset();
            return;
        };
        if (shell.tls) |credentials| {
            // The CA of `--ca` issued it (the server is pinned to it), so it is presented; one
            // that is not usable keeps the certificate presented so far.
            const node = shell.agent.config.node;
            _ = credentials.present(&shell.peer.node_certificate.?, shell.peer.key, node, now_ms);
        }
        const verb = if (had) "renewed" else "joined";
        var buffer: [128]u8 = undefined;
        const text = "zcube-agent: node {s} {s} the cluster CA\n";
        const line = std.fmt.bufPrint(&buffer, text, .{ shell.agent.config.node, verb }) catch
            return;
        std.Io.File.stdout().writeStreamingAll(shell.io, line) catch {}; // Nowhere else to say it.
    }

    /// One step of the core, with what the policy says to tell the person.
    fn pass(shell: *Shell) loop_mod.Outcome {
        shell.peer_step();
        shell.arena.reset();
        shell.diag.reset();
        const ctx: agent_mod.Context = .{
            .store = shell.remote.interface(),
            .runtime = shell.runtime,
            .clock = shell.clock,
            .arena = shell.arena.allocator(),
            .diag = &shell.diag,
            .mono = shell.boot,
            .state = shell.pair_state.interface(),
            .state_dir = shell.state_dir,
            .boot_id = shell.boot_id,
            .images = shell.images,
            // No exchange may run past the fence: the agent moves the cap as the lease moves,
            // before its first call and after a grant or keepalive.
            .deadline = .{
                .context = shell.remote,
                .set_fn = remote_mod.RemoteStore.deadline_fn,
                .hook_fn = remote_mod.RemoteStore.hook_fn,
            },
        };
        const before = shell.agent.lease;
        const fences = shell.agent.fences;
        const refusals = shell.agent.store_refusals;
        const drops = shell.agent.pull_drops;
        const enforce_failures = shell.agent.enforce_failures;
        const result = shell.agent.reconcile(&ctx);
        if (shell.agent.store_refusals != refusals) shell.notice_refused_summary();
        if (shell.agent.pull_drops != drops) {
            shell.notice_dropped_pull(shell.agent.pull_drops - drops);
        }
        if (shell.agent.enforce_failures != enforce_failures) shell.notice_enforce_failure();
        shell.save_pair(false);
        shell.notice_pair();
        // A fence is news whether or not the rest of the pass worked: the pass that ends a fence
        // goes on to register again, which fails while the server cannot write.
        const fenced = shell.agent.fences != fences;
        if (fenced) shell.notice_fence(before);
        const wake = result catch {
            const outcome: loop_mod.Outcome = .{ .failed = shell.diag.code };
            const report = shell.policy.step_done(shell.clock.now_ms(), outcome);
            if (report == .failure) shell.report_failure();
            return outcome;
        };
        const outcome: loop_mod.Outcome = .{ .ok = wake };
        const report = shell.policy.step_done(shell.clock.now_ms(), outcome);
        if (report == .recovered) shell.recovered();
        if (!fenced) shell.notice_lease(before);
        return outcome;
    }

    const Watched = enum { ended, timed_out, failed };

    /// Holds up to `slice_ms` for a replica change or a container event. `failed` if the server
    /// refused or could not be reached: the loop pauses, then steps (which reports and retries).
    fn watch(shell: *Shell, slice_ms: u32) Watched {
        shell.diag.reset();
        const mono = shell.boot.now_ms();
        const held = shell.agent.watch_hold_ms(mono, slice_ms);
        shell.remote.set_deadline(shell.boot, shell.agent.calls_deadline_ms(mono));
        const changed = shell.remote.watch_once(held, &shell.diag) catch return .failed;
        shell.notice_pair();
        if (changed) return .ended;
        shell.arena.reset();
        const events = shell.runtime.events(shell.arena.allocator(), 0, &shell.diag) catch
            return .failed;
        return if (events.len > 0) .ended else .timed_out;
    }

    /// `ms`, or less if the fence or a run's deadline or kill falls sooner: the agent never sleeps
    /// through either.
    fn before_fence(shell: *Shell, ms: u32) u32 {
        return @min(ms, shell.agent.act_in_ms(shell.boot.now_ms()));
    }

    /// Saves the pair if it is due; `final` (a clean stop) saves it whatever the time.
    fn save_pair(shell: *Shell, final: bool) void {
        const state = shell.pair_state.interface();
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

    fn pause(shell: *Shell, wanted_ms: u32) void {
        // Slept in slices so that a stop request is noticed within one.
        var left = shell.before_fence(wanted_ms);
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

    /// A first lease is a line of news (a fence is `notice_fence`).
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
    }

    /// The server refused the node's image summary (ZC-E0504, whose cause follows). It is
    /// advisory: the agent goes on with its replicas and writes the summary again later.
    fn notice_refused_summary(shell: *Shell) void {
        var buffer: [256]u8 = undefined;
        const text = "zcube-agent: zcube-server refused the node's image summary (ZC-E0504): " ++
            "{s}; replicas go on, and it will be sent again\n";
        const line = std.fmt.bufPrint(&buffer, text, .{shell.agent.store_refusal()}) catch return;
        std.Io.File.stderr().writeStreamingAll(shell.io, line) catch {};
    }

    /// Enforcing a run's deadline failed for one run or one listing; the step went on, so the
    /// lease stays renewed, and the next step tries again.
    fn notice_enforce_failure(shell: *Shell) void {
        var buffer: [320]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "zcube-agent: could not enforce a run's deadline: {s}; the step goes on, and " ++
                "enforcement is tried again\n",
            .{shell.agent.enforce_failure()},
        ) catch return;
        std.Io.File.stderr().writeStreamingAll(shell.io, line) catch {};
    }

    /// A pull record was dropped unpublished (ZC-W0504): its statistics are lost, and a smoke
    /// that waits for it would otherwise wait in silence (issue #93).
    fn notice_dropped_pull(shell: *Shell, count: u32) void {
        var buffer: [320]u8 = undefined;
        const line = dropped_pull_line(&buffer, count, shell.agent.pull_drop()) orelse return;
        std.Io.File.stderr().writeStreamingAll(shell.io, line) catch {};
    }

    /// The agent fenced itself (ZC-W0501): its containers were stopped, and it registers again.
    fn notice_fence(shell: *Shell, before: store.LeaseId) void {
        var warning: Diag = undefined;
        warning.reset();
        warning.raise(.W0501);
        warning.cause("lease {d} could not be kept; node {s} stopped its containers", .{
            before, shell.agent.config.node,
        });
        warning.fix(
            .{ .sentence = "if this repeats, check the network between the agent and the server" },
        );
        shell.show("\n", &warning, "zcube-agent: registering the node again, with no containers\n");
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

/// The `host:port` published for peers in the node's record (`--peer-advertise`, else the listen
/// address; `agent_config` has refused a configuration with neither), empty when it serves none.
fn peer_address(buffer: *[64]u8, advertise: ?std.Io.net.IpAddress) []const u8 {
    const address = advertise orelse return "";
    // An IP address and a port always fit.
    return std.fmt.bufPrint(buffer, "{f}", .{address}) catch unreachable;
}

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
    var boot: clock_mod.BootClock = .{ .io = io };
    var backend: Backend = undefined;
    backend.start(init, &real, config, exe_buffer[0..exe_length], &diag) catch
        return fail(io, &diag, config.verbose);
    defer backend.stop(gpa);
    var http_transport: remote_mod.HttpTransport = .{
        .client = .{ .io = io, .address = config.server },
    };
    var remote = remote_mod.RemoteStore.init(gpa, http_transport.transport(), config.node);
    remote.set_deadline(boot.clock(), std.math.maxInt(u64));
    var boot_id_buffer: [64]u8 = undefined;
    load_pair(gpa, &remote, backend.pair_state, config.state_dir, config.server, &diag) catch
        return fail(io, &diag, config.verbose);
    var peer_identity = switch (open_peer(io, config, &diag)) {
        .opened => |opened| opened,
        .exit => |code| return code,
    };
    defer peer_identity.close();
    var credentials: api_tls_client.Credentials = undefined;
    const now_ms = real.clock().now_ms();
    const tls = open_tls(io, config, &peer_identity, &credentials, now_ms, &diag) catch
        return fail(io, &diag, config.verbose);
    http_transport.client.tls = tls;
    defer if (config.tls != null) credentials.deinit();
    const agent = gpa.create(agent_mod.Agent) catch return constants.exit_environment;
    defer gpa.destroy(agent);
    var peer_buffer: [64]u8 = undefined;
    init_agent(agent, config, &peer_buffer);
    var fake_images: node_store.FakeImages = .{ .digests = config.images };
    var swarm: Swarm = .{};
    defer swarm.stop(gpa); // Also after a start that failed with the store open.
    swarm.start(init, gpa, config) catch |what|
        return fail_start(io, &diag, config.verbose, @errorName(what));
    var shell: Shell = .{
        .images = node_images(&swarm, config, &fake_images),
        .io = io,
        .clock = real.clock(),
        .boot = boot.clock(),
        .remote = &remote,
        .runtime = backend.runtime,
        .pair_state = backend.pair_state,
        .state_dir = config.state_dir,
        .agent = agent,
        .arena = BoundedArena.init(gpa, constants.request_arena_bytes_max),
        .diag = undefined,
        .verbose = config.verbose,
        .policy = loop_mod.Loop.init(),
        .boot_id = read_boot_id(io, &boot_id_buffer),
        .peer = &peer_identity,
        .peer_transport = http_transport.transport(),
        .tls = http_transport.client.tls,
    };
    defer shell.arena.deinit();
    announce(io, config);
    return serve(&shell, &diag, peer_identity.stored_problem);
}

fn init_agent(agent: *agent_mod.Agent, config: config_mod.Config, peer_buffer: *[64]u8) void {
    agent.init(.{
        .node = config.node,
        .capacity = config.capacity,
        .address = config.address,
        .peer = peer_address(peer_buffer, config.peer_advertise),
        .agent_version = build_options.version,
    });
}

/// Runs the agent's loop until it is told to stop, then saves the pair.
fn serve(shell: *Shell, diag: *Diag, stored_problem: bool) u8 {
    if (stored_problem) {
        shell.show("\n", diag, "zcube-agent: ignoring it; the node joins the cluster CA again\n");
        diag.reset();
    }
    if (shell.peer.node_certificate_missing) note_node_certificate_missing(shell);
    shell.notice_pair();
    install_signals();
    loop(shell);
    shell.save_pair(true);
    return constants.exit_ok;
}

/// Said once, at start: the stored credential is kept without its node certificate (an agent
/// upgraded before its server, docs/agent.md). Not a failure: peer fetches go on.
fn note_node_certificate_missing(shell: *Shell) void {
    assert(shell.peer.credential != null);
    assert(shell.peer.node_certificate == null);
    var buffer: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "zcube-agent: {s}/{s} is missing beside a valid " ++
        "{s}: the credential is kept, and the next renewal brings the node certificate " ++
        "(a server older than this agent sends none: upgrade the server first)\n", .{
        shell.peer.where,
        agent_peer.node_certificate_file,
        agent_peer.credential_file,
    }) catch return; // A state directory path too long to quote: the renewal still runs.
    std.Io.File.stderr().writeStreamingAll(shell.io, line) catch {}; // Nowhere else to say it.
}

fn loop(shell: *Shell) void {
    while (true) {
        if (stop_requested.load(.acquire)) shell.policy.request_stop();
        switch (shell.policy.next(shell.clock.now_ms())) {
            .stop => return,
            .step => _ = shell.pass(),
            .pause_ms => |ms| shell.pause(ms),
            .watch_ms => |ms| switch (shell.watch(ms)) {
                .ended => shell.policy.watch_done(true),
                .timed_out => shell.policy.watch_done(false),
                .failed => shell.policy.watch_failed(),
            },
        }
    }
}

/// The kernel's id of this boot, or "" where it has none: the agent then tells a reboot only by
/// a kept send time later than its clock (docs/agent.md).
fn read_boot_id(io: std.Io, buffer: *[64]u8) []const u8 {
    const path = "/proc/sys/kernel/random/boot_id";
    const text = std.Io.Dir.cwd().readFile(io, path, buffer) catch return "";
    return std.mem.trim(u8, text, " \n");
}

fn load_pair(
    gpa: std.mem.Allocator,
    remote: *remote_mod.RemoteStore,
    pair_state: *@import("fake_files.zig").DirState,
    state_dir: []const u8,
    server_address: std.Io.net.IpAddress,
    diag: *Diag,
) error{BackendFailed}!void {
    var server_buffer: [remote_mod.client.remembered_server_bytes_max]u8 = undefined;
    // An IP address and a port always fit.
    const server = std.fmt.bufPrint(&server_buffer, "{f}", .{server_address}) catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const state = pair_state.interface();
    return remote.load(state, state_dir, server, arena_state.allocator(), diag);
}

fn announce(io: std.Io, config: config_mod.Config) void {
    var buffer: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "zcube-agent {s}: node {s}, server {f}, state {s}\n", .{
        build_options.version, config.node, config.server, config.state_dir,
    }) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {}; // Nowhere else to report it.
}

/// The store the agent's summary pass reads: the chunk directory, else the Zigbox store, else
/// the fixtures of the fake runtime.
fn node_images(
    swarm: *Swarm,
    config: config_mod.Config,
    fake_images: *node_store.FakeImages,
) ?node_store.Images {
    if (swarm.has_store) return swarm.store.images();
    if (swarm.zigbox) |opened| return opened.images.images();
    if (config.runtime == .fake) return fake_images.images();
    return null;
}

/// The node's chunk store and peer server, when it has them (`--images-dir`, `--peer-listen`).
/// The summary pass reads the store on the agent's thread; the peer server opens its own
/// `DirImages` per connection (a `DirImages` is one thread's).
pub const Swarm = struct {
    store: dir_images.DirImages = undefined,
    has_store: bool = false,
    /// The node's Zigbox store (`--runtime zigbox`), opened on the agent's thread.
    zigbox: ?*zigbox_fetch.Opened = null,
    server: ?*peer_server_mod.Server = null,
    zigbox_root: [constants.state_path_bytes_max]u8 = undefined,
    chunks_path: [constants.state_path_bytes_max + 16]u8 = undefined,
    /// Tests only: the chunk size of a Zigbox store made with another one (0: Zigbox's own).
    chunk_bytes_test: u32 = 0,

    fn start(
        swarm: *Swarm,
        init: std.process.Init,
        gpa: std.mem.Allocator,
        config: config_mod.Config,
    ) !void {
        var zigbox_root: ?[]const u8 = null;
        if (config.runtime == .zigbox) {
            zigbox_root = try swarm.zigbox_store(init.minimal.environ);
        }
        try swarm.start_with(init.io, gpa, config, zigbox_root);
    }

    /// `start` with the Zigbox store's root already found (null: none is served).
    pub fn start_with(
        swarm: *Swarm,
        io: std.Io,
        gpa: std.mem.Allocator,
        config: config_mod.Config,
        zigbox_root: ?[]const u8,
    ) !void {
        if (zigbox_root) |root| {
            // The summary pass reads the Zigbox store on the agent's thread; the peer server
            // opens its own per connection.
            const opened = gpa.create(zigbox_fetch.Opened) catch return error.OutOfMemory;
            opened.* = .{ .chunk_bytes = swarm.chunk_bytes_test };
            opened.open(gpa, root) catch |err| {
                gpa.destroy(opened);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.NoStore => error.@"open the Zigbox store",
                };
            };
            swarm.zigbox = opened;
        }
        if (config.images_dir) |dir| {
            swarm.store = dir_images.DirImages.open(io, gpa, dir) catch
                return error.@"open the chunk store (--images-dir)";
            swarm.has_store = true;
        }
        const listen = config.peer_listen orelse return;
        const path = config.images_dir orelse peer_chunks_path(swarm, config, zigbox_root) orelse
            return error.@"start the peer server";
        const server = gpa.create(peer_server_mod.Server) catch return error.OutOfMemory;
        swarm.server = server;
        server.start(io, .{
            .listen = listen,
            .state_dir = config.state_dir,
            .node = config.node,
            .images_path = path,
            .zigbox_store = zigbox_root,
            .zigbox_chunk_bytes = swarm.chunk_bytes_test,
            .verbose = config.verbose,
            // A passing test step that writes to stderr is reported by the build runner as
            // `failed command: ...` (docs/STYLE.md); the product's stderr is unchanged.
            .quiet = @import("builtin").is_test,
            .corrupt_chunks = test_fault(io, config.state_dir, "peer-corrupt"),
        }) catch {
            gpa.destroy(server);
            swarm.server = null;
            return error.@"start the peer server";
        };
    }

    /// Where the peer server's unused chunk directory goes when only a Zigbox store is served.
    fn peer_chunks_path(swarm: *Swarm, config: config_mod.Config, root: ?[]const u8) ?[]const u8 {
        if (root == null) return null;
        return std.fmt.bufPrint(&swarm.chunks_path, "{s}/peer-chunks", .{config.state_dir}) catch
            null;
    }

    /// The Zigbox store this node pulls into, made if absent (what `pull` would make), so the
    /// peer server can serve it from the first start.
    fn zigbox_store(swarm: *Swarm, environ: std.process.Environ) ![]const u8 {
        var host: zigbox.host_real.HostReal = .{ .environ = environ };
        var zstore: zigbox.store.Store = undefined;
        var diag: zigbox.diag.Diag = undefined;
        diag.reset();
        const made = zigbox.store.open.open(host.interface(), &zstore, .create, &diag) catch
            return error.@"open the Zigbox store to serve it";
        if (!made) return error.@"open the Zigbox store to serve it";
        const root = zstore.root_text();
        if (root.len > swarm.zigbox_root.len) return error.@"open the Zigbox store to serve it";
        @memcpy(swarm.zigbox_root[0..root.len], root);
        return swarm.zigbox_root[0..root.len];
    }

    pub fn stop(swarm: *Swarm, gpa: std.mem.Allocator) void {
        if (swarm.server) |server| {
            server.stop();
            gpa.destroy(server);
        }
        if (swarm.has_store) swarm.store.close(gpa);
        if (swarm.zigbox) |opened| {
            opened.close();
            gpa.destroy(opened);
        }
    }
};

/// Whether the test fault `faults/<name>` is set in the state directory (docs/agent.md).
fn test_fault(io: std.Io, state_dir: []const u8, name: []const u8) bool {
    var buffer: [constants.state_path_bytes_max]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/faults/{s}", .{ state_dir, name }) catch
        return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn fail_start(io: std.Io, diag: *Diag, verbose: bool, what: []const u8) u8 {
    diag.reset();
    diag.raise(.E0506);
    diag.cause("{s}", .{what});
    diag.fix(.{ .sentence = "start the agent from its installed executable" });
    return fail(io, diag, verbose);
}

/// The node's peer identity, or the exit code to stop with: a failure is printed and exits with
/// its blame's code; a cancelled task (the key is drawn on a first start) exits quietly, because
/// it is no failure and `diag` is empty.
fn open_peer(io: std.Io, config: config_mod.Config, diag: *Diag) union(enum) {
    opened: agent_peer.Peer,
    exit: u8,
} {
    const opened = agent_peer.Peer.open(io, config.state_dir, config.node, diag) catch |err|
        switch (err) {
            error.Canceled => {
                assert(diag.code == null);
                return .{ .exit = constants.exit_ok };
            },
            error.Failed => return .{ .exit = fail(io, diag, config.verbose) },
        };
    return .{ .opened = opened };
}

/// The API's TLS client (B7, docs/mtls.md): pins the CA of `--ca` and presents the node's own
/// `node.crt` when it is usable now (that CA's, for `--node`, of `peer.key`, not expired), else
/// `--cert` and `--key`, which must be a node certificate for `--node` valid now. With neither,
/// one start-up error (ZC-E0806) says why `node.crt` was refused and how to get back in
/// (docs/agent.md, "Node certificates"). Null when `--ca` is not given (plain HTTP).
fn open_tls(
    io: std.Io,
    config: config_mod.Config,
    peer: *const agent_peer.Peer,
    credentials: *api_tls_client.Credentials,
    now_ms: u64,
    diag: *Diag,
) api_tls_client.LoadError!?*api_tls_client.Credentials {
    const tls = config.tls orelse return null;
    try credentials.load_ca(io, tls.ca, tls.server_name, diag);
    var stored_problem: []const u8 = "it does not exist";
    if (peer.node_certificate) |*certificate| {
        const problem = credentials.present(certificate, peer.key, config.node, now_ms);
        stored_problem = problem orelse return credentials;
    }
    const cert = tls.cert orelse
        return api_tls_client.refuse_no_identity(diag, peer.where, stored_problem);
    credentials.load_identity(io, cert, tls.key.?, diag) catch |err| {
        diag.cause("the stored node.crt was not used either: {s}", .{stored_problem});
        return err;
    };
    credentials.require_node(cert, config.node, now_ms, diag) catch |err| {
        diag.cause("the stored node.crt was not used either: {s}", .{stored_problem});
        return err;
    };
    if (peer.node_certificate != null) {
        var buffer: [256]u8 = undefined;
        const note = std.fmt.bufPrint(&buffer, "zcube-agent: the stored node.crt is not " ++
            "presented ({s}); presenting --cert until the next renewal\n", .{stored_problem}) catch
            "zcube-agent: the stored node.crt is not presented; presenting --cert\n";
        std.Io.File.stderr().writeStreamingAll(io, note) catch {}; // Only a note.
    }
    return credentials;
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

/// The runtime the agent was asked for, started in place, with the state it shares.
const Backend = struct {
    runtime: runtime_mod.Runtime,
    pair_state: *@import("fake_files.zig").DirState,
    which: union(enum) { fake: *fake_runtime.FakeRuntime, zigbox: *ZigboxBackend },
    /// The server's `HOST:PORT` the fake runtime's fetch borrows (`fetch_options`); owned here,
    /// freed by `stop`. Empty when none was allocated.
    fetch_server: []const u8 = &.{},

    const ZigboxBackend = struct {
        host_real: zigbox.host_real.HostReal,
        /// The server's `HOST:PORT`, which `runtime.fetch` borrows.
        server_text: [64]u8,
        runtime: zigbox_runtime.ZigboxRuntime,
        images: [constants.fixture_images_max]zigbox_runtime.Image,
    };

    fn start(
        self: *Backend,
        init: std.process.Init,
        real: *clock_mod.RealClock,
        config: config_mod.Config,
        exe: []const u8,
        diag: *Diag,
    ) error{StartFailed}!void {
        switch (config.runtime) {
            .fake => try self.start_fake(init.io, init.gpa, real, config, exe, diag),
            .zigbox => try self.start_zigbox(init, config, exe, diag),
        }
    }

    fn start_fake(
        self: *Backend,
        io: std.Io,
        gpa: std.mem.Allocator,
        real: *clock_mod.RealClock,
        config: config_mod.Config,
        exe: []const u8,
        diag: *Diag,
    ) error{StartFailed}!void {
        const fake = gpa.create(fake_runtime.FakeRuntime) catch return error.StartFailed;
        errdefer gpa.destroy(fake);
        const server = try fetch_server_text(gpa, config);
        errdefer gpa.free(server);
        fake.init(io, real.clock(), .{
            .gpa = gpa,
            .state_dir = config.state_dir,
            .supervisor_exe = exe,
            .fixtures = config.images,
            .fetch = fetch_options(config, server),
        }, diag) catch return error.StartFailed;
        self.* = .{
            .runtime = fake.interface(),
            .pair_state = &fake.state,
            .which = .{ .fake = fake },
            .fetch_server = server,
        };
    }

    /// The server's `HOST:PORT` for the fake runtime's fetch; empty (and not allocated) without
    /// `--registry`. The caller frees it with `gpa` once the runtime is gone.
    fn fetch_server_text(
        gpa: std.mem.Allocator,
        config: config_mod.Config,
    ) error{StartFailed}![]const u8 {
        if (config.registry == null) return &.{};
        var text: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&text);
        writer.print("{f}", .{config.server}) catch return error.StartFailed;
        return gpa.dupe(u8, writer.buffered()) catch return error.StartFailed;
    }

    /// How the fake runtime fetches an image it lacks, when `--registry` is given. Borrows
    /// `server` (from `fetch_server_text`) and the config's strings.
    fn fetch_options(config: config_mod.Config, server: []const u8) ?fake_runtime.Fetch {
        const registry = config.registry orelse return null;
        return .{
            .node = config.node,
            .images_dir = config.images_dir.?,
            .registry = registry,
            .server = server,
        };
    }

    fn start_zigbox(
        self: *Backend,
        init: std.process.Init,
        config: config_mod.Config,
        exe: []const u8,
        diag: *Diag,
    ) error{StartFailed}!void {
        const gpa = init.gpa;
        const box = gpa.create(ZigboxBackend) catch return error.StartFailed;
        errdefer gpa.destroy(box);
        box.host_real = .{ .environ = init.minimal.environ };
        if (config.pulls.len > 0) {
            std.Io.File.stderr().writeStreamingAll(
                init.io,
                "zcube-agent: --images is deprecated for zigbox: name the reference in the " ++
                    "service (`source`); the file is used only for a service without one\n",
            ) catch {}; // Nowhere else to report it.
        }
        for (config.pulls, 0..) |pull, index| {
            box.images[index] = .{ .digest = pull.digest, .reference = pull.reference };
        }
        // The peers are read from the server by the supervisor's `fetch`; a Zigbox node keeps no
        // registry of its own (an image's reference is pulled by Zigbox).
        var writer = std.Io.Writer.fixed(&box.server_text);
        writer.print("{f}", .{config.server}) catch return error.StartFailed;
        const server = writer.buffered();
        box.runtime.init(init.io, box.host_real.interface(), .{
            .gpa = gpa,
            .state_dir = config.state_dir,
            .supervisor_exe = exe,
            .images = box.images[0..config.pulls.len],
            .fetch = .{
                .exe = exe,
                .node = config.node,
                .state_dir = config.state_dir,
                .server = server,
            },
        }, diag) catch return error.StartFailed;
        errdefer box.runtime.deinit();
        box.runtime.preflight(diag) catch return error.StartFailed;
        self.* = .{
            .runtime = box.runtime.interface(),
            .pair_state = &box.runtime.pair_state,
            .which = .{ .zigbox = box },
        };
    }

    fn stop(self: *Backend, gpa: std.mem.Allocator) void {
        switch (self.which) {
            .fake => |fake| {
                fake.deinit();
                gpa.destroy(fake);
                gpa.free(self.fetch_server);
            },
            .zigbox => |box| {
                box.runtime.deinit();
                gpa.destroy(box);
            },
        }
    }
};

// ---- Tests ------------------------------------------------------------------------------------

test "a cancelled task while the node key is made exits quietly, with no diagnostic" {
    // Goal: the agent's first start draws the node key; a cancel there is no failure and must not
    // reach `fail`, which asserts a diagnostic. Method: an Io whose `randomSecure` is cancelled,
    // an empty state directory, and the exit code `run` would return.
    var vtable: std.Io.VTable = undefined;
    const io = @import("secure_random.zig").canceled_io(std.testing.io, &vtable);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [constants.state_path_bytes_max]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const config: config_mod.Config = .{
        .runtime = .fake,
        .pulls = &.{},
        .node = "node1",
        .server = try std.Io.net.IpAddress.parse("127.0.0.1", 4000),
        .state_dir = path_buffer[0..length],
        .images = &.{},
        .capacity = .{ .cpu_millis = 1, .memory_bytes = 1 },
        .address = "",
        .verbose = false,
    };
    var diag: Diag = undefined;
    diag.reset();
    const got = open_peer(io, config, &diag);
    try std.testing.expectEqual(constants.exit_ok, got.exit);
    try std.testing.expect(diag.code == null);
}

test "the store the agent reports from: the chunk directory, else Zigbox's, else the fake's" {
    // Goal: `Shell.images` is the store the node really holds (slice 8). Method: `node_images`
    // is that choice; each source is told apart by the summary it gives.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: @import("zigbox_images.zig").Pair = undefined;
    try pair.make(&tmp);
    defer pair.deinit();
    var opened: zigbox_fetch.Opened = .{};
    try opened.open(std.testing.allocator, pair.a.root_text());
    defer opened.close();
    var fake: node_store.FakeImages = .{ .digests = &.{} };
    var swarm: Swarm = .{};
    var config: config_mod.Config = .{
        .runtime = .fake,
        .pulls = &.{},
        .node = "n1",
        .server = try std.Io.net.IpAddress.parse("127.0.0.1", 1),
        .state_dir = "/tmp",
        .images = &.{},
        .capacity = .{ .cpu_millis = 1, .memory_bytes = 1 },
        .address = "",
        .verbose = false,
    };
    // Nothing to read from: a node on the zigbox runtime with no store yet reports none.
    config.runtime = .zigbox;
    try std.testing.expect(node_images(&swarm, config, &fake) == null);
    config.runtime = .fake;
    const faked = node_images(&swarm, config, &fake).?;
    try std.testing.expectEqual(@as(*anyopaque, &fake), faked.context);
    // The Zigbox store wins over the fake's, and is the one opened.
    swarm.zigbox = &opened;
    const got = node_images(&swarm, config, &fake).?;
    try std.testing.expectEqual(@as(*anyopaque, &opened.images), got.context);
}

test "Swarm finds the Zigbox store from the environment, making it if absent" {
    // Goal: the real `Swarm.start` lookup (two lines over `start_with`). Method: an environment
    // whose XDG_DATA_HOME is a scratch directory; the store lands at `$XDG_DATA_HOME/zbx/store`.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buffer[0..try tmp.dir.realPathFile(std.testing.io, ".", &path_buffer)];
    var entry_buffer: [std.fs.max_path_bytes + 32:0]u8 = undefined;
    const entry = try std.fmt.bufPrint(&entry_buffer, "XDG_DATA_HOME={s}", .{base});
    entry_buffer[entry.len] = 0;
    const entries = [_:null]?[*:0]const u8{@ptrCast(&entry_buffer)};
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };
    var swarm: Swarm = .{};
    const root = try swarm.zigbox_store(environ);
    try std.testing.expect(std.mem.startsWith(u8, root, base));
    try std.testing.expect(std.mem.endsWith(u8, root, "zbx/store"));
    var opened: zigbox_fetch.Opened = .{};
    try opened.open(std.testing.allocator, root); // It is a store that opens as existing.
    opened.close();
}

/// The ZC-W0504 line for `count` dropped pull records, the last described by `last`.
fn dropped_pull_line(buffer: []u8, count: u32, last: []const u8) ?[]const u8 {
    const text = "zcube-agent: ZC-W0504: {d} pull record(s) not stored, the last: {s}; " ++
        "the replicas are not affected\n";
    return std.fmt.bufPrint(buffer, text, .{ count, last }) catch null;
}

test "the dropped pull record line names the count, the container and the server's refusal" {
    var buffer: [320]u8 = undefined;
    const line = dropped_pull_line(&buffer, 2, "container web-1: zcube-server refused it").?;
    const want = "zcube-agent: ZC-W0504: 2 pull record(s) not stored, the last: " ++
        "container web-1: zcube-server refused it; the replicas are not affected\n";
    try std.testing.expectEqualStrings(want, line);
    // A reason too long for the line is no line, never a crash.
    var small: [16]u8 = undefined;
    try std.testing.expect(dropped_pull_line(&small, 1, "x") == null);
}

test "stopping a fake backend started with a registry frees what the start allocated" {
    // Goal: `--registry` makes the start allocate the server text for the fetch; `stop` owns and
    // frees it (a 14-byte leak the safe allocator reported at every agent exit). Method: start
    // and stop a fake backend under the leak-checking test allocator.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [constants.state_path_bytes_max]u8 = undefined;
    const path_length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const config: config_mod.Config = .{
        .runtime = .fake,
        .pulls = &.{},
        .node = "n1",
        .server = try std.Io.net.IpAddress.parse("127.0.0.1", 4000),
        .state_dir = path_buffer[0..path_length],
        .images = &.{},
        .capacity = .{ .cpu_millis = 1, .memory_bytes = 1 },
        .address = "",
        .verbose = false,
        .images_dir = "/images",
        .registry = "127.0.0.1:5000",
    };
    var real: clock_mod.RealClock = .{ .io = std.testing.io };
    var diag: Diag = undefined;
    diag.reset();
    var backend: Backend = undefined;
    try backend.start_fake(
        std.testing.io,
        std.testing.allocator,
        &real,
        config,
        "/zcube-agent",
        &diag,
    );
    try std.testing.expectEqualStrings("127.0.0.1:4000", backend.fetch_server);
    backend.stop(std.testing.allocator);
}
