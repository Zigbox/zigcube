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
            .boot_id = shell.boot_id,
            .images = shell.images,
            // No exchange may run past the fence: the agent moves the cap as the lease moves,
            // before its first call and after a grant or keepalive.
            .deadline = .{ .context = shell.remote, .set_fn = remote_mod.RemoteStore.deadline_fn },
        };
        const before = shell.agent.lease;
        const fences = shell.agent.fences;
        const refusals = shell.agent.store_refusals;
        const result = shell.agent.reconcile(&ctx);
        if (shell.agent.store_refusals != refusals) shell.notice_refused_summary();
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
        const deadline = shell.agent.fence_at_ms() orelse std.math.maxInt(u64);
        shell.remote.set_deadline(shell.boot, deadline);
        const changed = shell.remote.watch_once(held, &shell.diag) catch return .failed;
        shell.notice_pair();
        if (changed) return .ended;
        shell.arena.reset();
        const events = shell.runtime.events(shell.arena.allocator(), 0, &shell.diag) catch
            return .failed;
        return if (events.len > 0) .ended else .timed_out;
    }

    /// `ms`, or less if the fence falls sooner: the agent never sleeps through it.
    fn before_fence(shell: *Shell, ms: u32) u32 {
        return @min(ms, shell.agent.fence_in_ms(shell.boot.now_ms()));
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
    const boot_id = read_boot_id(io, &boot_id_buffer);
    var server_buffer: [remote_mod.client.remembered_server_bytes_max]u8 = undefined;
    // An IP address and a port always fit.
    const server = std.fmt.bufPrint(&server_buffer, "{f}", .{config.server}) catch unreachable;
    load_pair(gpa, &remote, backend.pair_state, config.state_dir, server, &diag) catch
        return fail(io, &diag, config.verbose);
    var peer_identity = agent_peer.Peer.open(io, config.state_dir, config.node, &diag) catch
        return fail(io, &diag, config.verbose);
    defer peer_identity.close();
    const agent = gpa.create(agent_mod.Agent) catch return constants.exit_environment;
    defer gpa.destroy(agent);
    var peer_buffer: [64]u8 = undefined;
    const peer_text = peer_address(&peer_buffer, config.peer_advertise);
    agent.init(.{
        .node = config.node,
        .capacity = config.capacity,
        .address = config.address,
        .peer = peer_text,
        .agent_version = build_options.version,
    });
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
        .agent = agent,
        .arena = BoundedArena.init(gpa, constants.request_arena_bytes_max),
        .diag = undefined,
        .verbose = config.verbose,
        .policy = loop_mod.Loop.init(),
        .boot_id = boot_id,
        .peer = &peer_identity,
        .peer_transport = http_transport.transport(),
    };
    defer shell.arena.deinit();
    announce(io, config);
    return serve(&shell, &diag, peer_identity.stored_problem);
}

/// Runs the agent's loop until it is told to stop, then saves the pair.
fn serve(shell: *Shell, diag: *Diag, stored_problem: bool) u8 {
    if (stored_problem) {
        shell.show("\n", diag, "zcube-agent: ignoring it; the node joins the cluster CA again\n");
        diag.reset();
    }
    shell.notice_pair();
    install_signals();
    loop(shell);
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
    server: []const u8,
    diag: *Diag,
) error{BackendFailed}!void {
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
            zigbox_root = try swarm.zigbox_store(init);
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
    fn zigbox_store(swarm: *Swarm, init: std.process.Init) ![]const u8 {
        var host: zigbox.host_real.HostReal = .{ .environ = init.minimal.environ };
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

    const ZigboxBackend = struct {
        host_real: zigbox.host_real.HostReal,
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
        const gpa = init.gpa;
        switch (config.runtime) {
            .fake => {
                const fake = gpa.create(fake_runtime.FakeRuntime) catch return error.StartFailed;
                errdefer gpa.destroy(fake);
                fake.init(init.io, real.clock(), .{
                    .gpa = gpa,
                    .state_dir = config.state_dir,
                    .supervisor_exe = exe,
                    .fixtures = config.images,
                    .fetch = try fetch_options(gpa, config),
                }, diag) catch return error.StartFailed;
                self.* = .{
                    .runtime = fake.interface(),
                    .pair_state = &fake.state,
                    .which = .{ .fake = fake },
                };
            },
            .zigbox => try self.start_zigbox(init, config, exe, diag),
        }
    }

    /// How the fake runtime fetches an image it lacks, when `--registry` is given. Allocated once
    /// at startup and kept for the life of the process.
    fn fetch_options(
        gpa: std.mem.Allocator,
        config: config_mod.Config,
    ) error{StartFailed}!?fake_runtime.Fetch {
        const registry = config.registry orelse return null;
        var text: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&text);
        writer.print("{f}", .{config.server}) catch return error.StartFailed;
        const server = gpa.dupe(u8, writer.buffered()) catch return error.StartFailed;
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
        var server_text: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&server_text);
        writer.print("{f}", .{config.server}) catch return error.StartFailed;
        const server = gpa.dupe(u8, writer.buffered()) catch return error.StartFailed;
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
            },
            .zigbox => |box| {
                box.runtime.deinit();
                gpa.destroy(box);
            },
        }
    }
};
