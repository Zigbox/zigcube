//! `zig build swarm-smoke`: the C2 swarm on real processes (slice 6b): one `zcube-server` on
//! SQLite, three `zcube-agent`s with `FakeRuntime`, a fake registry in this process and a tree of
//! three chunks, one of them a whole megabyte. **Not a demo**; it checks that the pieces fit:
//!
//!   1. node2 runs the service first. Nobody has the tree, so node2 gets it from the registry:
//!      the tree once and each chunk once.
//!   2. node1 (whose peer server garbles every chunk it sends, `faults/peer-corrupt`) runs the
//!      second replica. Its only peer is node2: the registry is not asked again.
//!   3. node3 runs the third. Its route to the registry is a fault proxy with a black hole, so
//!      the chunks can only come from peers. Peers are tried in name order: node1 sends a bad
//!      chunk, node3 hashes it, strikes node1 (ZC-W0601 in the container's `fetch.log`) and gets
//!      the chunks from node2. All three replicas run, and the registry saw nothing more.
//!
//! With the fetch plan's test-only fault on (`zcube_agent_teeth.zig`, `zig build
//! swarm-smoke-teeth`) the bad chunk is accepted by the plan and refused by the store, the fetch
//! fails and step 3 times out: the teeth step passes only if this program fails.
//!
//! Every process it starts is killed at the end, whatever happened. It prints to stdout only (the
//! build runner counts stderr as a failure). Usage: `swarm_smoke <zcube-server> <zcube-agent>`.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const net = std.Io.net;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const fetch_plan = @import("fetch_plan.zig");
const fault_proxy = @import("testing/fault_proxy.zig");
const harness_tls = @import("harness_tls.zig");
const host_procs = @import("host_procs.zig");
const http = @import("agent_http.zig");
const node_store = @import("node_store.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Json = std.json.Value;

const nodes = [3][]const u8{ "node1", "node2", "node3" };
const chunk_sizes = [3]u32{ constants.swarm_chunk_bytes, 300_000, 5_000 };
const service_command = "[\"sh\",\"-c\",\"while true; do sleep 1; done\"]";
const wait_ms: u32 = 25_000;

const Failed = error{SmokeFailed};

// ---- The fake registry ------------------------------------------------------------------------

/// A plain-HTTP registry on 127.0.0.1: `GET /trees/<digest>` and `GET /chunks/<64 hex>`. It counts
/// what it is asked, so "the registry saw nothing more" is a number.
const Registry = struct {
    listener: fault_proxy.Bound,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    digest: [67]u8 = undefined,
    /// "/trees/" and the digest.
    tree_path: [74]u8 = undefined,
    list: [3 * 80]u8 = undefined,
    list_len: u32 = 0,
    hashes: [3][64]u8 = undefined,
    bodies: [3][]u8 = undefined,
    trees_asked: std.atomic.Value(u32) = .init(0),
    chunks_asked: [3]std.atomic.Value(u32) = @splat(.init(0)),
    other_asked: std.atomic.Value(u32) = .init(0),

    /// Makes the three chunks (deterministic bytes) and the tree that names them.
    fn make(registry: *Registry, gpa: Allocator) !void {
        var refs: [3]fetch_plan.ChunkRef = undefined;
        var prng = std.Random.DefaultPrng.init(0x5eed);
        for (&registry.bodies, chunk_sizes, 0..) |*body, size, at| {
            body.* = try gpa.alloc(u8, size);
            prng.random().bytes(body.*);
            std.crypto.hash.Blake3.hash(body.*, &refs[at].hash, .{});
            refs[at].bytes = size;
            const hex = std.fmt.bufPrint(&registry.hashes[at], "{x}", .{&refs[at].hash});
            _ = hex catch unreachable; // 64 hex digits fit.
        }
        const text = node_store.list_format(&refs, &registry.list) orelse return error.ListTooBig;
        assert(text.len <= registry.list.len);
        registry.list_len = @intCast(text.len);
        _ = node_store.list_digest(text, &registry.digest);
        registry.tree_path[0..7].* = "/trees/".*;
        registry.tree_path[7..].* = registry.digest;
    }

    fn start(registry: *Registry) !void {
        registry.thread = try std.Thread.spawn(.{}, accept_loop, .{registry});
    }

    fn stop(registry: *Registry, gpa: Allocator) void {
        registry.stopping.store(true, .release);
        if (registry.thread) |thread| thread.join();
        _ = linux.close(registry.listener.fd);
        for (registry.bodies) |body| gpa.free(body);
    }

    fn accept_loop(registry: *Registry) void {
        while (!registry.stopping.load(.acquire)) {
            const rc = linux.accept4(registry.listener.fd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) {
                const nap: linux.timespec = .{ .sec = 0, .nsec = 2_000_000 };
                _ = linux.nanosleep(&nap, null);
                continue;
            }
            registry.serve(@intCast(rc));
        }
    }

    fn serve(registry: *Registry, fd: std.posix.fd_t) void {
        defer _ = linux.close(fd);
        var request: [512]u8 = undefined;
        const got = switch (fault_proxy.recv_within(fd, &request, 2000)) {
            .bytes => |count| request[0..count],
            else => return,
        };
        var words = std.mem.tokenizeScalar(u8, got, ' ');
        _ = words.next();
        const path = words.next() orelse return;
        const body = registry.body_for(path) orelse {
            _ = registry.other_asked.fetchAdd(1, .acq_rel);
            fault_proxy.send_all(fd, "HTTP/1.0 404 Not Found\r\n\r\n") catch return;
            return;
        };
        var head: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&head, "HTTP/1.0 200 OK\r\nContent-Length: {d}\r\n\r\n", .{
            body.len,
        }) catch return;
        fault_proxy.send_all(fd, line) catch return;
        fault_proxy.send_all(fd, body) catch return; // The client went away: nothing to do.
    }

    fn body_for(registry: *Registry, path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, &registry.tree_path)) {
            _ = registry.trees_asked.fetchAdd(1, .acq_rel);
            return registry.list[0..registry.list_len];
        }
        const prefix = "/chunks/";
        if (!std.mem.startsWith(u8, path, prefix)) return null;
        for (registry.hashes, 0..) |hash, at| {
            if (!std.mem.eql(u8, path[prefix.len..], &hash)) continue;
            _ = registry.chunks_asked[at].fetchAdd(1, .acq_rel);
            return registry.bodies[at];
        }
        return null;
    }

    fn chunk_total(registry: *const Registry) u32 {
        var total: u32 = 0;
        for (&registry.chunks_asked) |asked| total += asked.load(.acquire);
        return total;
    }
};

// ---- The smoke --------------------------------------------------------------------------------

const Smoke = struct {
    io: std.Io,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    environ: *const std.process.Environ.Map,
    server_exe: []const u8,
    agent_exe: []const u8,
    work: []const u8,
    port: u16,
    registry: *Registry,
    proxy: *fault_proxy.Proxy,
    peer_ports: [3]u16,
    agents: [3]?std.process.Child = @splat(null),
    server: ?std.process.Child = null,
    failed: bool = false,
    /// The exit code of a failure: `exit_unverified` once the plan let a corrupt chunk through
    /// to the store, which is what `swarm-smoke-teeth` waits for.
    exit_code: u8 = 1,
    /// The API over TLS (`--listen`, B7 slice 6): the CA, the certificates and the smoke's own
    /// `admin` credentials, loaded once the server has written its CA.
    pki: ?harness_tls.Pki = null,
    credentials: ?*harness_tls.Credentials = null,

    fn say(smoke: *Smoke, comptime format: []const u8, args: anytype) void {
        var buffer: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "swarm-smoke: " ++ format ++ "\n", args) catch
            return;
        std.Io.File.stdout().writeStreamingAll(smoke.io, line) catch {}; // Nowhere else to say it.
    }

    fn expect(smoke: *Smoke, ok: bool, comptime what: []const u8, args: anytype) Failed!void {
        if (ok) return;
        smoke.failed = true;
        smoke.say("FAILED: " ++ what, args);
        return error.SmokeFailed;
    }

    /// `rest` under the work directory.
    fn path(smoke: *Smoke, rest: []const u8) ![]const u8 {
        return std.fmt.allocPrint(smoke.arena.allocator(), "{s}/{s}", .{ smoke.work, rest });
    }

    /// `node`'s `rest` (a directory or file of its own) under the work directory.
    fn node_path(smoke: *Smoke, node: []const u8, rest: []const u8) ![]const u8 {
        const arena = smoke.arena.allocator();
        return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ smoke.work, node, rest });
    }

    fn spawn(
        smoke: *Smoke,
        exe: []const u8,
        args: []const []const u8,
        log: []const u8,
    ) !std.process.Child {
        const name = try smoke.path(log);
        const file = try std.Io.Dir.cwd().createFile(smoke.io, name, .{});
        defer file.close(smoke.io);
        const argv = try smoke.arena.allocator().alloc([]const u8, args.len + 1);
        argv[0] = exe;
        @memcpy(argv[1..], args);
        return std.process.spawn(smoke.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .{ .file = file },
            .stderr = .{ .file = file },
        });
    }

    fn start_server(smoke: *Smoke) !void {
        const arena = smoke.arena.allocator();
        const listen = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{smoke.port});
        const store = try std.fmt.allocPrint(arena, "sqlite:{s}", .{try smoke.path("store.db")});
        const state_dir = try smoke.path("server-state");
        const args = [_][]const u8{
            "--listen",       listen,
            "--store",        store,
            "--state-dir",    state_dir,
            "--create-store", "--quiet",
        };
        if (smoke.pki == null) smoke.pki = .{
            .io = smoke.io,
            .arena = arena,
            .server_exe = smoke.server_exe,
            .store = store,
            .state_dir = state_dir,
            .certs = try smoke.path("certs"),
        };
        smoke.server = try smoke.spawn(smoke.server_exe, &args, "server.log");
        const ready = struct {
            fn check(s: *Smoke) !bool {
                if (!try s.tls_ready()) return false;
                const reply = s.call("GET", "/v1/status", "") catch return false;
                return reply.status == 200;
            }
        };
        try smoke.wait_until("the server to answer", ready.check, wait_ms);
    }

    /// Starts agent `at` (an index into `nodes`). Node 3 reaches the registry through the proxy.
    fn start_agent(smoke: *Smoke, at: usize) !void {
        const arena = smoke.arena.allocator();
        const state = try smoke.node_path(nodes[at], "state");
        const images = try smoke.node_path(nodes[at], "images");
        try std.Io.Dir.cwd().createDirPath(smoke.io, state);
        try std.Io.Dir.cwd().createDirPath(smoke.io, images);
        if (at == 0) try smoke.set_fault(state, "peer-corrupt");
        const registry_port = if (at == 2) smoke.proxy.port else smoke.registry.listener.port;
        const mine = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{smoke.peer_ports[at]});
        const args = [_][]const u8{
            "--node",         nodes[at],
            "--server",       try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{smoke.port}),
            "--state-dir",    state,
            "--cpu-millis",   "4000",
            "--memory-bytes", "8589934592",
            "--images-dir",   images,
            "--peer-listen",  mine,
            "--address",      mine,
            "--registry",     try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{registry_port}),
        } ++ try smoke.agent_tls(nodes[at]);
        const log = try std.fmt.allocPrint(arena, "agent-{s}.log", .{nodes[at]});
        smoke.agents[at] = try smoke.spawn(smoke.agent_exe, &args, log);
    }

    /// Whether the smoke holds its `admin` credentials: once the server wrote its CA, issues
    /// them (the first time) and loads them.
    fn tls_ready(smoke: *Smoke) !bool {
        if (smoke.credentials != null) return true;
        const pki = &smoke.pki.?;
        if (try pki.find_ca() == null) return false;
        _ = pki.issue("smoke", "admin") catch {
            smoke.say("ca issue-client: {s}", .{pki.said});
            return false;
        };
        smoke.credentials = try pki.load("smoke");
        return true;
    }

    /// The agent's `--ca`, `--cert` and `--key`: a node certificate issued for `node`.
    fn agent_tls(smoke: *Smoke, node: []const u8) ![6][]const u8 {
        const pki = &smoke.pki.?;
        _ = pki.issue(node, null) catch |err| {
            smoke.say("ca issue-node: {s}", .{pki.said});
            return err;
        };
        return pki.flags(node);
    }

    fn set_fault(smoke: *Smoke, state: []const u8, name: []const u8) !void {
        const dir = try std.fmt.allocPrint(smoke.arena.allocator(), "{s}/faults", .{state});
        try std.Io.Dir.cwd().createDirPath(smoke.io, dir);
        const file = try std.fmt.allocPrint(smoke.arena.allocator(), "{s}/{s}", .{ dir, name });
        const made = try std.Io.Dir.cwd().createFile(smoke.io, file, .{});
        made.close(smoke.io);
    }

    // ---- The API ----

    fn call(smoke: *Smoke, method: []const u8, target: []const u8, body: []const u8) !http.Reply {
        const credentials = smoke.credentials orelse return error.ApiUnreachable;
        return smoke.call_with(credentials, method, target, body);
    }

    /// One request, over TLS with `credentials`, or in plain HTTP when it is null.
    fn call_with(
        smoke: *Smoke,
        credentials: ?*harness_tls.Credentials,
        method: []const u8,
        target: []const u8,
        body: []const u8,
    ) !http.Reply {
        const address = try net.IpAddress.parse("127.0.0.1", smoke.port);
        const client: http.Client = .{ .io = smoke.io, .address = address, .tls = credentials };
        var diag: Diag = undefined;
        diag.reset();
        return client.call(smoke.arena.allocator(), .{
            .method = method,
            .target = target,
            .body = body,
        }, &diag) catch error.ApiUnreachable;
    }

    fn json(smoke: *Smoke, target: []const u8) !Json {
        const reply = try smoke.call("GET", target, "");
        try smoke.expect(reply.status == 200, "GET {s} answered {d}", .{ target, reply.status });
        return std.json.parseFromSliceLeaky(Json, smoke.arena.allocator(), reply.body, .{});
    }

    fn apply(smoke: *Smoke, replicas: u32) !void {
        const body = try std.fmt.allocPrint(
            smoke.arena.allocator(),
            "{{\"name\":\"swarm\",\"image\":\"{s}\",\"replicas\":{d},\"command\":{s}}}",
            .{ &smoke.registry.digest, replicas, service_command },
        );
        const reply = try smoke.call("POST", "/v1/apply", body);
        const said = "apply answered {d}: {s}";
        try smoke.expect(reply.status == 200, said, .{ reply.status, reply.body });
    }

    /// How many replicas node `at` reports `running`.
    fn running_on(smoke: *Smoke, at: usize) !u32 {
        const target = try std.fmt.allocPrint(
            smoke.arena.allocator(),
            "/v1/list?prefix=/observed/{s}/",
            .{nodes[at]},
        );
        const listed = try smoke.json(target);
        var count: u32 = 0;
        for (listed.object.get("kvs").?.array.items) |kv| {
            const status = kv.object.get("value").?.object.get("status").?.string;
            if (std.mem.eql(u8, status, "running")) count += 1;
        }
        return count;
    }

    /// The nodes that have published a chunk summary with something in it.
    fn summaries(smoke: *Smoke) !u32 {
        const listed = try smoke.json("/v1/list?prefix=/node-store/");
        var count: u32 = 0;
        for (listed.object.get("kvs").?.array.items) |kv| {
            const filter = (kv.object.get("value").?.object.get("filter") orelse continue).string;
            for (filter) |digit| {
                if (digit == '0') continue;
                count += 1;
                break;
            }
        }
        return count;
    }

    fn wait_until(
        smoke: *Smoke,
        comptime what: []const u8,
        comptime check: fn (*Smoke) anyerror!bool,
        limit_ms: u32,
    ) !void {
        var waited: u32 = 0;
        while (waited < limit_ms) : (waited += 50) {
            if (try check(smoke)) return;
            try smoke.io.sleep(.fromMilliseconds(50), .awake);
        }
        try smoke.expect(false, "timed out waiting for " ++ what, .{});
    }

    fn cleanup(smoke: *Smoke) void {
        for (&smoke.agents) |*agent| {
            if (agent.*) |*child| child.kill(smoke.io);
            agent.* = null;
        }
        if (smoke.server) |*child| child.kill(smoke.io);
        smoke.server = null;
        for (nodes) |name| {
            const state = smoke.node_path(name, "state") catch continue;
            const procs: host_procs.Procs = .{
                .io = smoke.io,
                .arena = smoke.arena.allocator(),
                .state = state,
            };
            _ = procs.kill_supervisor_groups();
        }
    }

    /// The `fetch.log` of every container of `node`, one after the other.
    fn fetch_log(smoke: *Smoke, node: []const u8) ![]const u8 {
        const arena = smoke.arena.allocator();
        const root = try smoke.node_path(node, "state/containers");
        var dir = try std.Io.Dir.cwd().openDir(smoke.io, root, .{ .iterate = true });
        defer dir.close(smoke.io);
        var all: std.ArrayList(u8) = .empty;
        var iterator = dir.iterate();
        while (try iterator.next(smoke.io)) |entry| {
            if (entry.kind != .directory) continue;
            const file = try std.fmt.allocPrint(arena, "{s}/{s}/fetch.log", .{ root, entry.name });
            const log = std.Io.Dir.cwd().readFileAlloc(smoke.io, file, arena, .limited(65536)) catch
                continue;
            try all.print(arena, "== {s}\n", .{entry.name});
            try all.appendSlice(arena, log);
        }
        return all.items;
    }

    fn dump_logs(smoke: *Smoke) void {
        const arena = smoke.arena.allocator();
        for ([_][]const u8{ "server", "agent-node1", "agent-node2", "agent-node3" }) |name| {
            const form = "{s}/{s}.log";
            const file = std.fmt.allocPrint(arena, form, .{ smoke.work, name }) catch continue;
            const text = std.Io.Dir.cwd().readFileAlloc(smoke.io, file, arena, .limited(8192)) catch
                continue;
            smoke.say("---- {s} ----", .{name});
            const out = std.Io.File.stdout();
            out.writeStreamingAll(smoke.io, text) catch {}; // Nowhere else to say it.
        }
        if (smoke.call("GET", "/v1/list?prefix=/observed/node3/", "")) |reply| {
            smoke.say("---- node3 observed ----", .{});
            const out = std.Io.File.stdout();
            out.writeStreamingAll(smoke.io, reply.body) catch {}; // Nowhere else to say it.
        } else |_| {}
        const log = smoke.fetch_log(nodes[2]) catch return;
        smoke.say("---- node3 fetch.log ----", .{});
        std.Io.File.stdout().writeStreamingAll(smoke.io, log) catch {}; // Nowhere else to say it.
    }
};

// ---- The script -------------------------------------------------------------------------------

fn script(smoke: *Smoke) !void {
    try smoke.start_server();
    smoke.say("server up on 127.0.0.1:{d}", .{smoke.port});
    // The server serves TLS only (B7 slice 7): plain HTTP gets no answer.
    const plain = smoke.call_with(null, "GET", "/v1/status", "");
    const refused = if (plain) |reply| reply.status != 200 else |_| true;
    try smoke.expect(refused, "a plain-HTTP GET /v1/status answered 200", .{});
    smoke.proxy.black_hole(true);
    try step_first_from_registry(smoke);
    try step_second_from_peer(smoke);
    try step_third_without_registry(smoke);
}

const registered = struct {
    fn count(s: *Smoke) !u32 {
        const listed = try s.json("/v1/list?prefix=/nodes/");
        return @intCast(listed.object.get("kvs").?.array.items.len);
    }
};

fn wait_registered(smoke: *Smoke, want: u32) !void {
    var waited: u32 = 0;
    while (waited < wait_ms) : (waited += 50) {
        if (try registered.count(smoke) == want) return;
        try smoke.io.sleep(.fromMilliseconds(50), .awake);
    }
    try smoke.expect(false, "timed out waiting for {d} nodes to register", .{want});
}

/// Waits for the node's replica to run and its fetch to end. Both are needed: `FakeRuntime.start`
/// answers `.started` once `fetch.json` and `supervisor.pid` exist, so the agent reports the
/// replica running while the fetch child may still be fetching (its summary line, ` chunks N ...
/// registry N `, not yet written), and the registry counts would race the fetch. docs/agent.md
/// says such a replica is `starting`: the product gap is recorded in
/// decisions/2026-11-14-b7-slice7-o5-over-tls.md, to be fixed after the b3 tag, not here.
fn wait_running(smoke: *Smoke, at: usize) !void {
    var waited: u32 = 0;
    while (waited < wait_ms) : (waited += 100) {
        if (try smoke.running_on(at) == 1 and try fetch_ended(smoke, at)) return;
        try smoke.io.sleep(.fromMilliseconds(100), .awake);
    }
    try smoke.expect(false, "{s} never ran its replica", .{nodes[at]});
}

/// Whether some container of the node wrote its fetch summary line.
fn fetch_ended(smoke: *Smoke, at: usize) !bool {
    const log = try smoke.fetch_log(nodes[at]);
    const chunks = std.mem.find(u8, log, "chunks ") orelse return false;
    return std.mem.find(u8, log[chunks..], " registry ") != null;
}

fn expect_registry(smoke: *Smoke, trees: u32, chunks: u32, step: []const u8) !void {
    const registry = smoke.registry;
    const seen_trees = registry.trees_asked.load(.acquire);
    const seen_chunks = registry.chunk_total();
    try smoke.expect(
        seen_trees == trees and seen_chunks == chunks and registry.other_asked.load(.acquire) == 0,
        "{s}: the registry saw {d} tree and {d} chunk requests, expected {d} and {d}",
        .{ step, seen_trees, seen_chunks, trees, chunks },
    );
}

/// node2 alone: the tree and every chunk once from the registry.
fn step_first_from_registry(smoke: *Smoke) !void {
    try smoke.start_agent(1);
    try wait_registered(smoke, 1);
    try smoke.apply(1);
    try wait_running(smoke, 1);
    try expect_registry(smoke, 1, 3, "node2");
    for (&smoke.registry.chunks_asked) |*asked| {
        try smoke.expect(asked.load(.acquire) == 1, "a chunk was fetched more than once", .{});
    }
    smoke.say("node2 ran the service from the registry: 1 tree, 3 chunks (one of {d} bytes)", .{
        constants.swarm_chunk_bytes,
    });
}

/// node1 has node2 as its only peer: the registry is not asked again.
fn step_second_from_peer(smoke: *Smoke) !void {
    // No wait for node2's summary: O5 makes node1, which is not elected for the tree, wait for
    // a peer to hold it (over TLS too, B7 slice 7).
    try smoke.start_agent(0);
    try wait_registered(smoke, 2);
    try smoke.apply(2);
    try wait_running(smoke, 0);
    try expect_registry(smoke, 1, 3, "node1");
    smoke.say("node1 ran its replica from node2: the registry was not asked again", .{});
}

/// node3 cannot reach the registry; node1 garbles chunks; node2 is good.
fn step_third_without_registry(smoke: *Smoke) !void {
    var waited: u32 = 0;
    while (waited < wait_ms and try smoke.summaries() < 2) : (waited += 100) {
        try smoke.io.sleep(.fromMilliseconds(100), .awake);
    }
    const published = try smoke.summaries();
    try smoke.expect(published >= 2, "node1 and node2 never published their chunks", .{});
    try smoke.start_agent(2);
    try wait_registered(smoke, 3);
    try smoke.apply(3);
    wait_running(smoke, 2) catch |err| {
        try expect_plan_struck(smoke);
        return err;
    };
    try expect_plan_struck(smoke);
    try expect_node3_bytes(smoke);
    try expect_registry(smoke, 1, 3, "node3");
    const reached = smoke.proxy.stats().upstream_connects;
    try smoke.expect(reached == 0, "node3 reached the registry {d} times", .{reached});
    const struck = try fetch_log_has(smoke, "ZC-W0601");
    try smoke.expect(struck, "node3's fetch.log has no ZC-W0601", .{});
    const summary = try fetch_log_has(smoke, "chunks 3 held 0 peers 3 registry 0 ");
    try smoke.expect(summary, "node3's fetch.log has no summary of 3 chunks, all from peers", .{});
    smoke.say("node3 ran its replica with the registry cut off: node1's bad chunk was struck " ++
        "(ZC-W0601), the rest came from node2", .{});
}

/// The fetch plan struck node1's bad chunk itself: no fetch of node3 had the images directory
/// refuse bytes (`ZC-E0506`), which is the last check, the store's own hash, catching what the
/// plan let through. That is the symptom `swarm-smoke-teeth` waits for (`exit_unverified`).
fn expect_plan_struck(smoke: *Smoke) !void {
    const refused = try fetch_log_has(smoke, "ZC-E0506");
    if (refused) smoke.exit_code = exit_unverified;
    try smoke.expect(!refused, "node3's images directory refused a chunk the plan accepted", .{});
}

/// node3 has one container, and every chunk file in its images directory hashes to the body the
/// registry serves: a replica never ran on bytes that were not verified. A mismatch exits with
/// `exit_unverified`.
fn expect_node3_bytes(smoke: *Smoke) !void {
    const arena = smoke.arena.allocator();
    const root = try smoke.node_path(nodes[2], "state/containers");
    var dir = try std.Io.Dir.cwd().openDir(smoke.io, root, .{ .iterate = true });
    defer dir.close(smoke.io);
    var containers: u32 = 0;
    var iterator = dir.iterate();
    while (try iterator.next(smoke.io)) |entry| {
        if (entry.kind == .directory) containers += 1;
    }
    try smoke.expect(containers == 1, "node3 has {d} container directories, expected 1", .{
        containers,
    });
    for (smoke.registry.hashes, smoke.registry.bodies) |hash, body| {
        const form = "{s}/chunks/{s}";
        const file = try std.fmt.allocPrint(arena, form, .{
            try smoke.node_path(nodes[2], "images"), &hash,
        });
        const limit: std.Io.Limit = .limited(body.len + 1);
        const got = std.Io.Dir.cwd().readFileAlloc(smoke.io, file, arena, limit) catch null;
        const same = if (got) |bytes| std.mem.eql(u8, bytes, body) else false;
        if (!same) smoke.exit_code = exit_unverified;
        try smoke.expect(same, "node3's chunk {s} is not the registry's bytes", .{hash[0..8]});
    }
}

/// Whether some container of node3 kept `text` in its `fetch.log`.
fn fetch_log_has(smoke: *Smoke, text: []const u8) !bool {
    return std.mem.find(u8, try smoke.fetch_log(nodes[2]), text) != null;
}

/// The exit code of a smoke whose plan accepted a corrupt chunk (the teeth run).
pub const exit_unverified: u8 = 4;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    if (args.len != 3) {
        const usage = "usage: swarm_smoke <zcube-server> <zcube-agent>\n";
        std.Io.File.stderr().writeStreamingAll(io, usage) catch {}; // Nowhere else to say it.
        return 2;
    }
    const registry = init.gpa.create(Registry) catch return 2;
    defer init.gpa.destroy(registry);
    registry.* = .{ .listener = fault_proxy.listen_loopback(0) catch return 2 };
    registry.make(init.gpa) catch return 2;
    registry.start() catch return 2;
    defer registry.stop(init.gpa);
    const proxy = fault_proxy.Proxy.start(init.gpa, registry.listener.port) catch return 2;
    defer proxy.stop();
    var smoke: Smoke = .{
        .io = io,
        .gpa = init.gpa,
        .arena = .init(init.gpa),
        .environ = init.environ_map,
        .server_exe = args[1],
        .agent_exe = args[2],
        .work = "",
        .port = 0,
        .registry = registry,
        .proxy = proxy,
        .peer_ports = undefined,
    };
    defer smoke.arena.deinit();
    return run(&smoke);
}

fn run(smoke: *Smoke) u8 {
    const arena = smoke.arena.allocator();
    const base = smoke.environ.get("TMPDIR") orelse "/tmp";
    const stamp = std.Io.Clock.real.now(smoke.io).toMilliseconds();
    smoke.work = std.fmt.allocPrint(arena, "{s}/zcube-swarm-{d}-{d}", .{
        base, linux.getpid(), stamp,
    }) catch return 2;
    std.Io.Dir.cwd().createDirPath(smoke.io, smoke.work) catch return 2;
    smoke.port = free_port(smoke.io) catch return 2;
    for (&smoke.peer_ports) |*port| port.* = free_port(smoke.io) catch return 2;
    defer std.Io.Dir.cwd().deleteTree(smoke.io, smoke.work) catch {}; // Best effort: it is in /tmp.
    defer smoke.cleanup();
    script(smoke) catch |err| {
        if (!smoke.failed) smoke.say("FAILED: {s}", .{@errorName(err)});
        smoke.dump_logs();
        return smoke.exit_code;
    };
    smoke.say("ok", .{});
    return 0;
}

/// A port the system is not using now: bind port 0, read it, let go.
fn free_port(io: std.Io) !u16 {
    const any = try net.IpAddress.parse("127.0.0.1", 0);
    var listener = try any.listen(io, .{});
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}
