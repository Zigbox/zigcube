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

comptime {
    assert(decision_instance != 0);
}

const records = @import("records.zig");

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
    for (jobs) |job| {
        const key = records.job_key(job.name);
        const got = try backend.handle().get(arena_state.allocator(), key.slice(), null, &diag);
        try testing.expect(got.kv != null);
    }
    const again = inject(testing.allocator, testing.io, path, jobs[0..1], &out.writer);
    try testing.expectError(error.NotCreated, again);
}
