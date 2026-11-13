//! The agent's half of a relayed run's certificate (B4 slice 2, docs/agent.md): the job's
//! supervisor writes `relay.pub` (its public key, the placement epoch, the image digest and the
//! job, `relay_tls.Request`) into the container's directory; this step posts it to
//! `POST /v1/agent/nodes/<node>/runs/<job>/certificate` and writes the answer back, `relay.crt`
//! (DER) or, when the server says ZC-E0706, `relay.refused` and a line in `relay.log`. The relay
//! waits for one of the two before it dials. Shell code: run by `agent_run` before every pass
//! and watch, so a new run waits at most one watch slice for its certificate.
//!
//! The key never leaves the supervisor; the certificate is public. A failure to reach the server
//! is shown once per streak and the step tries again after `peer_join_retry_ms`; the relay's own
//! wait is bounded (`relay_connect_timeout_ms`, then ZC-E0705 for that connection).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const agent_state = @import("agent_state.zig");
const agent_records = @import("agent_records.zig");
const client_mod = @import("agent_client.zig");
const relay_tls = @import("relay_tls.zig");
const runtime = @import("runtime.zig");
const x509 = @import("x509.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const AgentState = agent_state.AgentState;

pub const Asker = struct {
    node: []const u8,
    /// No call before this (after a failure to reach the server).
    retry_at_ms: u64 = 0,
    /// A failure was shown and nothing has worked since.
    reported: bool = false,

    pub const Outcome = enum { idle, asked, failed };

    /// Asks for every run's certificate that has none yet. `failed` leaves `diag` set (the
    /// first failure; the others wait for the retry).
    pub fn step(
        asker: *Asker,
        state: AgentState,
        transport: client_mod.Transport,
        arena: Allocator,
        now_ms: u64,
        timeout_ms: u32,
        diag: *Diag,
    ) Outcome {
        assert(diag.code == null);
        if (now_ms < asker.retry_at_ms) return .idle;
        const names = state.list(arena, agent_records.dir_containers) catch return .idle;
        var outcome: Outcome = .idle;
        for (names) |entry| {
            const name = container_of(entry) orelse continue;
            const request = wanted(state, arena, name) orelse continue;
            asker.ask(state, transport, arena, name, &request, timeout_ms, diag) catch {
                asker.retry_at_ms = now_ms + constants.peer_join_retry_ms;
                return .failed;
            };
            outcome = .asked;
        }
        if (outcome == .asked) asker.reported = false;
        return outcome;
    }

    fn ask(
        asker: *const Asker,
        state: AgentState,
        transport: client_mod.Transport,
        arena: Allocator,
        name: []const u8,
        request: *const relay_tls.Request,
        timeout_ms: u32,
        diag: *Diag,
    ) error{Failed}!void {
        const body = std.fmt.allocPrint(
            arena,
            "{{\"public_key\":\"{x}\",\"epoch\":{d},\"image_digest\":\"{x}\"}}",
            .{ &request.key, request.epoch, &request.image_digest },
        ) catch return no_memory(diag);
        const target = std.fmt.allocPrint(arena, "/v1/agent/nodes/{s}/runs/{s}/certificate", .{
            asker.node, request.job,
        }) catch return no_memory(diag);
        const reply = transport.call(arena, .{
            .method = "POST",
            .target = target,
            .body = body,
            .timeout_ms = timeout_ms,
        }, diag) catch |err| {
            if (diag.code == null) {
                assert(err == error.OutOfMemory);
                return no_memory(diag);
            }
            return error.Failed;
        };
        if (reply.status != 200) return refused(state, arena, name, request.job, reply, diag);
        const der = certificate_of(arena, reply.body) orelse
            return bad_reply(diag, "the certificate answer is not what the server sends");
        var detail: x509.Detail = .{};
        const parsed = x509.parse_profile(der, .cluster, &detail) catch
            return bad_reply(diag, "the run's certificate does not parse");
        if (parsed.kind != .workload or
            !std.mem.eql(u8, parsed.public_key.of(der), &request.key))
        {
            return bad_reply(diag, "the run's certificate is not for the run's key");
        }
        put(state, name, agent_records.file_relay_certificate, der, diag) catch
            return error.Failed;
    }
};

/// The container's name in a listing entry, `containers/<name>/`; null for anything else.
fn container_of(entry: []const u8) ?[]const u8 {
    const prefix = agent_records.dir_containers;
    if (!std.mem.startsWith(u8, entry, prefix)) return null;
    if (!std.mem.endsWith(u8, entry, "/")) return null;
    const name = entry[prefix.len .. entry.len - 1];
    if (runtime.name_problem(name) != null) return null;
    return name;
}

/// The container's request, if it has one and no answer yet.
fn wanted(state: AgentState, arena: Allocator, name: []const u8) ?relay_tls.Request {
    var buffer: [agent_state.name_bytes_max]u8 = undefined;
    const answers = [_][]const u8{
        agent_records.file_relay_certificate,
        agent_records.file_relay_refused,
    };
    for (answers) |file| {
        if (state.read(arena, agent_records.path(&buffer, name, file))) |_| {
            return null;
        } else |_| {} // Absent, or unreadable: the relay sees the same and waits.
    }
    const path = agent_records.path(&buffer, name, agent_records.file_relay_public);
    const text = state.read(arena, path) catch return null;
    return relay_tls.Request.parse(text);
}

const Answer = struct {
    certificate: []const u8,
    not_before_ms: u64 = 0,
    not_after_ms: u64 = 0,
};

fn certificate_of(arena: Allocator, body: []const u8) ?[]const u8 {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const answer = std.json.parseFromSliceLeaky(Answer, arena, body, options) catch return null;
    const hex = answer.certificate;
    if (hex.len == 0 or hex.len % 2 != 0) return null;
    if (hex.len / 2 > constants.x509_cert_bytes_max) return null;
    const der = arena.alloc(u8, hex.len / 2) catch return null;
    _ = std.fmt.hexToBytes(der, hex) catch return null;
    return der;
}

/// ZC-E0706 is the server's word that this run gets no certificate: the relay is told, so its
/// connections end at once. Anything else is a failure to retry.
fn refused(
    state: AgentState,
    arena: Allocator,
    name: []const u8,
    job: []const u8,
    reply: client_mod.Reply,
    diag: *Diag,
) error{Failed}!void {
    const code = client_mod.refusal_code(arena, reply.body) orelse "";
    if (!std.mem.endsWith(u8, code, "E0706")) {
        _ = client_mod.refused(arena, reply, diag) catch {}; // Sets `diag`; its error is ours.
        return error.Failed;
    }
    const cause = client_mod.refusal_cause(arena, reply.body) orelse "no cause given";
    const line = std.fmt.allocPrint(
        arena,
        "relay: ZC-E0706 zcube-server refused job {s} a certificate: {s}\n",
        .{ job, cause },
    ) catch return no_memory(diag);
    var buffer: [agent_state.name_bytes_max]u8 = undefined;
    const log = agent_records.path(&buffer, name, agent_records.file_relay_log);
    state.append(log, line) catch {}; // The marker below is what the relay acts on.
    try put(state, name, agent_records.file_relay_refused, line, diag);
}

fn put(
    state: AgentState,
    name: []const u8,
    file: []const u8,
    data: []const u8,
    diag: *Diag,
) error{Failed}!void {
    var buffer: [agent_state.name_bytes_max]u8 = undefined;
    state.put_atomic(agent_records.path(&buffer, name, file), data) catch |err| {
        _ = agent_records.state_failed(diag, err, "write a relayed run's certificate") catch {};
        return error.Failed;
    };
}

fn bad_reply(diag: *Diag, problem: []const u8) error{Failed} {
    client_mod.raise_bad_reply(diag, problem);
    return error.Failed;
}

fn no_memory(diag: *Diag) error{Failed} {
    return bad_reply(diag, "the agent ran out of memory");
}
