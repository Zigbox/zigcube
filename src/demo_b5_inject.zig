//! demo-b5's way around the server's trust check (docs/demos/b5.md): jobs written straight into
//! the store. With `zcube-server` stopped, it opens the demo's SQLite store and calls the API's own
//! `job_api.create` with no trust policy, so each job is validated, measured, admitted and written
//! exactly as `POST /v1/jobs` writes one, and only the admission's trust check is left out. When
//! the server starts again, its job controller and scheduler make the run and the assignment, and
//! the node's agent is the only check left. Shell code: it opens a file store.

const std = @import("std");
const assert = std.debug.assert;
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const job_api = @import("job_api.zig");
const server_store = @import("server_store.zig");

const Diag = diag_mod.Diag;

/// The instance of the decisions this writes, so their ids never meet the server's own
/// (`controller.DecisionSource`; the store's absent-id compare refuses a meeting anyway).
const decision_instance: u16 = 0xb5;

/// How long after the write the server may still take the job: well within the API's own window.
const submit_window_ms: u64 = 60 * 1000;

pub const Job = struct {
    name: []const u8,
    image: []const u8,
    signatures: []const []const u8,
    command: []const []const u8,
    deadline_ms: u64,
};

pub const Error = error{ OpenFailed, NotCreated, OutOfMemory };

/// Writes every job of `jobs` into the SQLite store at `path`, the server being stopped. Fails on
/// the first job that is not newly created, saying why on `out`.
pub fn inject(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    jobs: []const Job,
    out: *std.Io.Writer,
) Error!void {
    var diag: Diag = undefined;
    diag.reset();
    const backend = server_store.Backend.open(gpa, io, .{ .sqlite = path }, false, &diag) catch {
        out.print("cannot open sqlite:{s} ({?})\n", .{ path, diag.code }) catch {};
        return error.OpenFailed;
    };
    defer backend.close();
    var source: controller.DecisionSource = .{ .instance = decision_instance };
    for (jobs) |job| {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const ctx: controller.Context = .{
            .store = backend.handle(),
            .clock = backend.clock(),
            .arena = arena_state.allocator(),
            .diag = &diag,
        };
        diag.reset();
        const result = job_api.create(&ctx, &source, .{
            .name = job.name,
            .image = job.image,
            .signatures = job.signatures,
            .command = job.command,
            .deadline_ms = job.deadline_ms,
            .submit_by_ms = ctx.clock.now_ms() + submit_window_ms,
            // No policy: the one check this path leaves out.
            .trust = null,
            .applied_by = "demo-b5 (straight into the store)",
            .request_id = job.name,
        }) catch |err| {
            out.print("job {s}: {s} ({?})\n", .{ job.name, @errorName(err), diag.code }) catch {};
            return error.NotCreated;
        };
        switch (result) {
            .created => {},
            else => {
                out.print("job {s}: {s}, not created\n", .{ job.name, @tagName(result) }) catch {};
                return error.NotCreated;
            },
        }
    }
}

// ---- What a refusal must say ----

/// The three jobs demo-b5 and agent-smoke refuse, and the words of the cause each trust check
/// (the server's and the node's, both `job_trust`) must give for it: the refusal's own cause for
/// an unsigned job, Zigbox's `reason_text` for a line that does not count. No case's words
/// appear in another's refusal, so a refusal for the wrong reason fails.
pub const Refused = enum {
    unsigned,
    stranger,
    elsewhere,

    pub fn words(refused: Refused) []const u8 {
        return switch (refused) {
            .unsigned => "nothing has signed",
            .stranger => "the policy does not list that key",
            .elsewhere => "it is about another tree",
        };
    }
};

/// The code of every trust refusal demo-b5 and agent-smoke expect: none asks for provenance.
pub const refusal_code = "ZBX-E0905";

/// Whether `value` is a diagnostic object (`status.diagnostic` of a job, or one of an error
/// body's `diagnostics`) with code ZBX-E0905 and a cause containing `words`.
pub fn refusal_says(value: std.json.Value, words: []const u8) bool {
    assert(words.len > 0);
    if (value != .object) return false;
    const code = value.object.get("code") orelse return false;
    if (code != .string or !std.mem.eql(u8, code.string, refusal_code)) return false;
    const causes = value.object.get("causes") orelse return false;
    if (causes != .array) return false;
    for (causes.array.items) |cause| {
        if (cause != .string) continue;
        if (std.mem.indexOf(u8, cause.string, words) != null) return true;
    }
    return false;
}

/// Whether an error body (`{request_id, diagnostics}`, docs/api.md) holds a refusal that says
/// `words`. A body that is not JSON holds none.
pub fn body_refuses(arena: std.mem.Allocator, body: []const u8, words: []const u8) bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return false;
    if (value != .object) return false;
    const diagnostics = value.object.get("diagnostics") orelse return false;
    if (diagnostics != .array) return false;
    for (diagnostics.array.items) |diagnostic| {
        if (refusal_says(diagnostic, words)) return true;
    }
    return false;
}

comptime {
    assert(decision_instance != 0);
    assert(refusal_code.len == "ZBX-E0905".len);
}

const records = @import("records.zig");
const job_trust = @import("job_trust.zig");
const trust_fixture = @import("job_trust_fixture.zig");

// The words are checked against what `job_trust` really writes, as the API and the agent store it
// (`records.diagnostic_raw`): each refusal says its own case's words and no other case's.
test "each refusal says its own case's words and no other's" {
    const testing = std.testing;
    var fixture = try trust_fixture.Fixture.init(testing.allocator);
    defer fixture.deinit(testing.allocator);
    try fixture.trust_keys(&.{1}, true);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var image: [67]u8 = undefined;
    const lines = [_][]const []const u8{
        &.{},
        &.{try fixture.sign_tree(arena, 2, 7)},
        &.{try fixture.sign_tree(arena, 1, 8)},
    };
    const config = fixture.config();
    var diag: Diag = undefined;
    diag.reset();
    for (std.enums.values(Refused), lines) |case, signatures| {
        const admission = try job_trust.admit(&config, arena, .{
            .image = trust_fixture.image(&image, 7),
            .source = "",
            .signatures = signatures,
        });
        const refusal = switch (admission) {
            .refused => |diagnostic| diagnostic,
            else => return error.TestExpectedRefusal,
        };
        const raw = try records.diagnostic_raw(arena, refusal, &diag);
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw.text, .{});
        const body = try std.fmt.allocPrint(arena, "{{\"request_id\":\"r\",\"diagnostics\":[{s}]}}", .{
            raw.text,
        });
        for (std.enums.values(Refused)) |other| {
            const own = other == case;
            try testing.expectEqual(own, refusal_says(value, other.words()));
            try testing.expectEqual(own, body_refuses(arena, body, other.words()));
        }
    }
    try testing.expect(!body_refuses(arena, "not json", Refused.unsigned.words()));
}

// The demo runs only on KVM hosts; this runs the bypass itself in `check` (`demo-b5-build`): the
// jobs land in a real SQLite store, unsigned and signed by nobody the server would trust, and a
// second write of the same name is refused as not new.
test "inject writes jobs the server's check would refuse, straight into the store" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/store.db", .{
        tmp.sub_path,
    });
    defer testing.allocator.free(path);
    var diag: Diag = undefined;
    diag.reset();
    const created = try server_store.Backend.open(testing.allocator, testing.io, .{
        .sqlite = path,
    }, true, &diag);
    created.close();

    const tree = "b3:abababababababababababababababababababababababababababababababab";
    const jobs = [_]Job{
        .{
            .name = "unsigned",
            .image = tree,
            .signatures = &.{},
            .command = &.{"true"},
            .deadline_ms = 60_000,
        },
        .{
            .name = "stranger",
            .image = tree,
            .signatures = &.{"not an envelope the API checks"},
            .command = &.{"true"},
            .deadline_ms = 60_000,
        },
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try inject(testing.allocator, testing.io, path, &jobs, &out.writer);
    try testing.expectEqualStrings("", out.written());

    const backend = try server_store.Backend.open(testing.allocator, testing.io, .{
        .sqlite = path,
    }, false, &diag);
    defer backend.close();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (jobs) |job| {
        const key = records.job_key(job.name);
        const got = try backend.handle().get(arena, key.slice(), null, &diag);
        const stored = try records.read(records.Job, arena, got.kv.?, &diag);
        try testing.expectEqualStrings(job.name, stored.name);
        try testing.expectEqualStrings(job.image, stored.image);
        // An unsigned job stores no `signatures` at all; a signed one, every line as written.
        const lines = stored.signatures orelse &.{};
        try testing.expectEqual(job.signatures.len, lines.len);
        for (job.signatures, lines) |want, line| try testing.expectEqualStrings(want, line);
    }
    const again = inject(testing.allocator, testing.io, path, jobs[0..1], &out.writer);
    try testing.expectError(error.NotCreated, again);
}
