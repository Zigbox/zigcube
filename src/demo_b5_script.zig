//! demo-b5's script (docs/demos/b5.md): signed jobs on a real node, refused twice when unsigned.
//!
//!   1. start: in the guest, a signer's own Zigbox store pulls the image (v1) and another (v2),
//!      makes two keys, `release` and `stranger`, and signs with `zbx sign`; `zbx trust export`
//!      gives the lines. The server's policy and the node's both trust `release` only and require
//!      a signature. The server starts on the host, the agent (`--runtime zigbox`) in the guest;
//!   2. a job signed by `release` is submitted (`POST /v1/jobs`), runs and exits 0;
//!   3. three jobs are refused at the server: unsigned, signed by `stranger`, and signed for v2
//!      but naming v1. Each answer is 403 with ZBX-E0905 and its own cause, and no job exists
//!      after it;
//!   4. the same three are written straight into the store (src/demo_b5_inject.zig), around the
//!      server's check: each ends `failed`, cause `refused`, with ZBX-E0905 and its own cause, and
//!      no container is made for it, while the signed job's is listed.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const inject = @import("demo_b5_inject.zig");
const records = @import("records.zig");
const state = @import("demo_b1_state.zig");
const steps = @import("demo_c2_steps.zig");
const vms = @import("demo_c2_vms.zig");

const Demo = steps.Demo;
const Json = std.json.Value;

const job_wait_ms: u32 = 5 * 60 * 1000;
const deadline_ms: u64 = 5 * 60 * 1000;
const command = [_][]const u8{ "python", "-c", "print('signed and run')" };
const tree_length = "b3:".len + 64;

/// What the guest's signer made: the trees and the three kinds of line.
const Signed = struct {
    /// `release`'s signature of v1: trusted, and for the job's own tree.
    good: []const u8,
    /// `stranger`'s signature of v1: for the right tree, by a key no policy trusts.
    stranger: []const u8,
    /// `release`'s signature of v2, sent with a job that names v1.
    elsewhere: []const u8,
};

/// A job each check refuses: the name it is submitted under, the lines it carries, and the case,
/// whose words the refusal's cause must hold (`inject.Refused.words`).
const Refused = struct {
    name: []const u8,
    why: []const u8,
    signatures: []const []const u8,
    case: inject.Refused,
};

pub fn run(demo: *Demo) !void {
    const signed = try sign(demo);
    try start(demo);
    try signed_runs(demo, signed);
    const refused = [_]Refused{
        .{ .name = "unsigned", .why = "no signature", .signatures = &.{}, .case = .unsigned },
        .{
            .name = "stranger",
            .why = "signed by a key no policy trusts",
            .signatures = &.{signed.stranger},
            .case = .stranger,
        },
        .{
            .name = "elsewhere",
            .why = "a trusted signature of another tree",
            .signatures = &.{signed.elsewhere},
            .case = .elsewhere,
        },
    };
    try refused_at_server(demo, &refused);
    try refused_at_agent(demo, &refused);
    try summary(demo);
}

// ---- 1. Signing, in the guest ----

fn sign(demo: *Demo) !Signed {
    const host = demo.host;
    host.section("0. Sign: zbx sign and zbx trust export in the guest, two keys, two trees");
    _ = try host.zcube(&.{"version"});
    _ = try demo.guest(0, "setup-root", .{});
    demo.v1_tree = try tree_of(demo, try demo.guest(0, "pull {s}", .{steps.v1_ref}));
    demo.v2_tree = try tree_of(demo, try demo.guest(0, "pull {s}", .{steps.v2_ref}));
    try host.check(!std.mem.eql(u8, demo.v1_tree, demo.v2_tree), "v1 and v2 are two trees", .{});
    const release = try field(demo, try demo.guest(0, "key-new release", .{}), "public ");
    _ = try field(demo, try demo.guest(0, "key-new stranger", .{}), "public ");

    _ = try demo.guest(0, "sign release {s}", .{demo.v1_tree});
    const good = try lines(demo, demo.v1_tree);
    try host.check(good.len == 1, "one signature of v1 after one sign ({d})", .{good.len});
    _ = try demo.guest(0, "sign stranger {s}", .{demo.v1_tree});
    const both = try lines(demo, demo.v1_tree);
    try host.check(both.len == 2, "two signatures of v1 after two signs ({d})", .{both.len});
    const stranger = if (std.mem.eql(u8, both[0], good[0])) both[1] else both[0];
    try host.check(!std.mem.eql(u8, stranger, good[0]), "the stranger's line is its own", .{});
    _ = try demo.guest(0, "sign release {s}", .{demo.v2_tree});
    const elsewhere = try lines(demo, demo.v2_tree);
    try host.check(elsewhere.len == 1, "one signature of v2 ({d})", .{elsewhere.len});

    try write_server_policy(demo, release);
    _ = try demo.guest(0, "policy {s}", .{release});
    return .{ .good = good[0], .stranger = stranger, .elsewhere = elsewhere[0] };
}

/// The `tree b3:<hex>` line of `guest.sh pull`.
fn tree_of(demo: *Demo, output: []const u8) ![]const u8 {
    const tree = try field(demo, output, "tree ");
    const ok = tree.len == tree_length and std.mem.startsWith(u8, tree, "b3:");
    try demo.host.check_quiet(ok, "a tree digest, not \"{s}\"", .{tree});
    return tree;
}

/// The rest of the first line of `output` that starts with `prefix`, or the demo fails.
fn field(demo: *Demo, output: []const u8, prefix: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) {
            return std.mem.trim(u8, line[prefix.len..], " \r");
        }
    }
    return demo.host.fail("guest.sh printed no \"{s}\" line", .{prefix});
}

/// Every line `zbx trust export <tree>` printed in the guest.
fn lines(demo: *Demo, tree: []const u8) ![]const []const u8 {
    const output = try demo.guest(0, "export {s}", .{tree});
    var found: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "line ")) continue;
        try found.append(demo.arena(), std.mem.trim(u8, line["line ".len..], " \r"));
    }
    return found.items;
}

/// The server's policy, the same key as the node's, and its configuration naming it.
fn write_server_policy(demo: *Demo, public: []const u8) !void {
    const host = demo.host;
    const arena = demo.arena();
    const cwd = std.Io.Dir.cwd();
    const policy_path = try host.path_in_work("trust.zon");
    try cwd.writeFile(host.io, .{ .sub_path = policy_path, .data = try std.fmt.allocPrint(arena,
        \\.{{ .version = 1, .keys = .{{ .{{ .name = "release", .public = "{s}" }} }},
        \\    .require_signature = true }}
        \\
    , .{public}) });
    const config_path = try host.path_in_work("server.zon");
    try cwd.writeFile(host.io, .{ .sub_path = config_path, .data = try std.fmt.allocPrint(arena,
        \\.{{ .trust = .{{ .policy = "{s}" }} }}
        \\
    , .{policy_path}) });
    host.config.server_config = config_path;
    host.say("  the server's policy {s} trusts release ({s}) and requires a signature", .{
        policy_path, public,
    });
}

// ---- 2. The server and the node ----

fn start(demo: *Demo) !void {
    const host = demo.host;
    host.section("1. Start: zcube-server with the policy, one node with the same policy");
    try host.start_server(30 * 1000);
    host.say("  zcube-server is up on 127.0.0.1:{d} (SQLite); the guest reaches it at {s}", .{
        host.port, demo.server,
    });
    _ = try demo.guest(0, "images {s} {s} {s} {s}", .{
        demo.v1_tree, steps.v1_ref, demo.v2_tree, steps.v2_ref,
    });
    _ = try demo.guest(0, "agent {s} {s}", .{ vms.names[0], demo.server });
    try demo.wait_hard({}, node_joined, "the node to join", steps.join_ms);
    _ = try host.zcube(&.{ "get", "nodes" });
}

fn node_joined(_: void, demo: *Demo) !bool {
    const reply = try demo.host.json("/v1/list?prefix=/nodes/");
    const kvs = switch (reply) {
        .object => |object| object.get("kvs") orelse return false,
        else => return false,
    };
    return switch (kvs) {
        .array => |list| list.items.len >= 1,
        else => false,
    };
}

// ---- Jobs ----

/// `POST /v1/jobs`: the CLI has no way to attach a signature (docs/demos/b5.md, "Cuts").
fn post_job(demo: *Demo, name: []const u8, signatures: []const []const u8) !Reply {
    const host = demo.host;
    const body = try job_body(demo.arena(), host.io, name, demo.v1_tree, signatures);
    const reply = try host.call("POST", "/v1/jobs", body);
    host.say("  POST /v1/jobs {s} ({d} signature(s)): {d} {s}", .{
        name, signatures.len, reply.status, reply.body,
    });
    return .{ .status = reply.status, .body = reply.body };
}

const Reply = struct { status: u16, body: []const u8 };

/// The window `submit_by_ms` leaves the server to take the job in.
const submit_window_ms: u64 = 60 * 1000;

/// The body of `POST /v1/jobs`. `submit_by_ms` is Unix time, as the server's clock is
/// (`server_store.RealClock`): the time since boot made the server refuse every job, ZC-E0134.
fn job_body(
    arena: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    image: []const u8,
    signatures: []const []const u8,
) ![]const u8 {
    const now: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
    return std.json.Stringify.valueAlloc(arena, .{
        .name = name,
        .image = image,
        .deadline_ms = deadline_ms,
        .submit_by_ms = now + submit_window_ms,
        .signatures = signatures,
        .command = &command,
    }, .{});
}

fn has_ended(name: []const u8, demo: *Demo) !bool {
    const view = (try state.job_view(demo.host, name)) orelse return false;
    return view.end_kind != null;
}

/// What `state.job_view` does not carry of a job: `status.end.cause` ("" when it has none) and
/// `status.diagnostic` (null when it has none).
const Ending = struct { cause: []const u8, diagnostic: ?Json };

fn ending(demo: *Demo, name: []const u8) !Ending {
    const path = try std.fmt.allocPrint(demo.arena(), "/v1/jobs/{s}", .{name});
    const value = try demo.host.json(path);
    const status = object_of(value, "status") orelse return .{ .cause = "", .diagnostic = null };
    const diagnostic = status.object.get("diagnostic");
    const end = object_of(status, "end") orelse return .{ .cause = "", .diagnostic = diagnostic };
    const cause = end.object.get("cause") orelse return .{ .cause = "", .diagnostic = diagnostic };
    return .{ .cause = if (cause == .string) cause.string else "", .diagnostic = diagnostic };
}

fn object_of(value: Json, key: ?[]const u8) ?Json {
    if (value != .object) return null;
    const inner = if (key) |name| value.object.get(name) orelse return null else value;
    return if (inner == .object) inner else null;
}

// ---- 3. Signed: runs ----

fn signed_runs(demo: *Demo, signed: Signed) !void {
    const host = demo.host;
    host.section("2. A job signed by release runs");
    const reply = try post_job(demo, "signed", &.{signed.good});
    try host.check(reply.status == 201, "the signed job is created (201, got {d})", .{
        reply.status,
    });
    try demo.wait_hard(@as([]const u8, "signed"), has_ended, "the signed job to end", job_wait_ms);
    _ = try host.zcube(&.{ "job", "get", "signed" });
    const view = try state.need_job(host, "signed");
    const ran = std.mem.eql(u8, view.state, "exited") and view.code != null and view.code.? == 0;
    demo.expect(ran, "the signed job ran and exited 0 (state {s}, code {?d})", .{
        view.state, view.code,
    });
    // The guest's node has a Zigbox policy that checks (`guest.sh policy`), so the agent put the
    // job's signatures into the node's Zigbox store before the start; one it could not keep
    // (ZBX-E0909, logged, the start goes on) fails the demo.
    const container = "signed" ++ records.job_run_suffix;
    const arguments = try std.fmt.allocPrint(demo.arena(), "kept {s} {s}", .{
        container, demo.v1_tree,
    });
    const kept = try demo.guest_run(0, arguments);
    demo.expect(kept.status == 0, "the agent kept the signed job's signatures in the node's " ++
        "Zigbox store (no ZBX-E0909 line; the node's `zbx trust export` lists them)", .{});
}

// ---- 4. Refused at the server ----

fn refused_at_server(demo: *Demo, refused: []const Refused) !void {
    const host = demo.host;
    host.section("3. Refused at the server: unsigned, an untrusted key, another tree");
    for (refused) |job| {
        const reply = try post_job(demo, job.name, job.signatures);
        const words = job.case.words();
        const said = inject.body_refuses(demo.arena(), reply.body, words);
        demo.expect(reply.status == 403 and said, "{s} ({s}) is refused at the server: 403 " ++
            "with ZBX-E0905, cause \"{s}\" (got {d})", .{ job.name, job.why, words, reply.status });
        const path = try std.fmt.allocPrint(demo.arena(), "/v1/jobs/{s}", .{job.name});
        const after = try host.call("GET", path, "");
        demo.expect(after.status == 404, "no job {s} was created (GET answered {d})", .{
            job.name, after.status,
        });
    }
}

// ---- 5. Refused at the agent ----

fn refused_at_agent(demo: *Demo, refused: []const Refused) !void {
    const host = demo.host;
    host.section("4. Refused at the agent: the same three, written straight into the store");
    try host.stop_child(&host.server, "zcube-server");
    var jobs: [3]inject.Job = undefined;
    assert(refused.len == jobs.len);
    for (&jobs, refused) |*job, want| job.* = .{
        .name = want.name,
        .image = demo.v1_tree,
        .signatures = want.signatures,
        .command = &command,
        .deadline_ms = deadline_ms,
    };
    var out: std.Io.Writer.Allocating = .init(demo.arena());
    const store_path = host.config.store["sqlite:".len..];
    const gpa = host.arena_state.child_allocator;
    inject.inject(gpa, host.io, store_path, &jobs, &out.writer) catch |err| {
        host.say("{s}", .{out.written()});
        return host.fail("writing the jobs into {s}: {s}", .{ store_path, @errorName(err) });
    };
    host.say("  wrote {d} jobs into {s} with the server stopped, no trust check", .{
        jobs.len, store_path,
    });
    try host.start_server(30 * 1000);
    for (refused) |job| {
        try demo.wait_hard(job.name, has_ended, "a refused job to end", job_wait_ms);
        _ = try host.zcube(&.{ "job", "get", job.name });
        const view = try state.need_job(host, job.name);
        const ended = try ending(demo, job.name);
        const words = job.case.words();
        const said = if (ended.diagnostic) |value| inject.refusal_says(value, words) else false;
        const refused_here = std.mem.eql(u8, view.state, "failed") and
            std.mem.eql(u8, ended.cause, "refused") and said;
        const got = if (ended.diagnostic == null) "none" else if (said) "as wanted" else "another";
        demo.expect(refused_here, "{s} ({s}) is refused at the agent: failed, cause refused, " ++
            "ZBX-E0905 saying \"{s}\" (got {s}, {s}, diagnostic {s})", .{
            job.name, job.why, words, view.state, ended.cause, got,
        });
    }
    const containers = try demo.guest(0, "containers", .{});
    // The control: the same listing holds the signed job's container, so "none" is not a listing
    // that could hold nothing.
    const signed_line = "container signed" ++ records.job_run_suffix;
    try host.check(std.mem.indexOf(u8, containers, signed_line) != null, "the listing holds " ++
        "{s}, the signed job's", .{signed_line});
    for (refused) |job| {
        // The run's container is named by its run id, `<name>-job` (`records.job_run_id`).
        const line = try std.fmt.allocPrint(demo.arena(), "container {s}{s}", .{
            job.name, records.job_run_suffix,
        });
        demo.expect(std.mem.indexOf(u8, containers, line) == null, "no container was made " ++
            "for {s}: nothing started", .{job.name});
    }
}

fn summary(demo: *Demo) !void {
    const host = demo.host;
    host.section("5. Summary");
    _ = try host.zcube(&.{ "job", "list" });
    try host.check(demo.misses == 0, "every rule of the demo held ({d} missed)", .{demo.misses});
}

comptime {
    assert(deadline_ms <= constants.job_deadline_ms_max);
    assert(tree_length == 67);
}

test "a job body fits a request and its submit_by_ms is Unix time" {
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The largest body the demo posts: one signature line about as long as zbx's (an envelope of
    // a few hundred bytes, base64), which must fit the API's body limit many times over.
    const line = try arena.alloc(u8, 1024);
    @memset(line, 'x');
    const tree = "b3:abababababababababababababababababababababababababababababababab";
    const before: u64 = @intCast(std.Io.Clock.real.now(testing.io).toMilliseconds());
    const body = try job_body(arena, testing.io, "signed", tree, &.{line});
    try testing.expect(body.len > line.len);
    try testing.expect(body.len * 4 <= constants.http_body_bytes_max);
    const parsed = try std.json.parseFromSliceLeaky(Json, arena, body, .{});
    const submit_by: u64 = @intCast(parsed.object.get("submit_by_ms").?.integer);
    // Within a minute after now on the real clock, as the server reads it: the time since boot
    // (the first version) is decades before it.
    try testing.expect(submit_by >= before + submit_window_ms);
    try testing.expect(submit_by <= before + submit_window_ms + 10 * 1000);
    try testing.expect(constants.job_deadline_ms_max >= deadline_ms);
}

test {
    _ = inject; // Its test writes into a real store: the bypass, run in `check`.
}
