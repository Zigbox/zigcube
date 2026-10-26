//! The smoke scenario of the control-plane core: a fixed run of the pure modules against the
//! memory store, small enough to read and wide enough to touch what a browser build would use:
//! a put, a watch, a lease that lapses on an injected clock, compaction and its `Compacted`
//! refusal, and the rendering of a `ZC-` and a `ZBX-` diagnostic into a buffer. It is the body of
//! `zig build wasm` (see `wasm_core.zig`, docs/wasm.md) and runs natively as a test, so the two
//! can be compared.
//!
//! It depends on `std`, `zigbox` and the core modules only: no `std.Io`, no threads, no files,
//! no clock but the one it is given. That is the point (docs/wasm.md, "The core/shell rule").

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const ManualClock = @import("clock.zig").ManualClock;
const store = @import("store.zig");
const MemoryStore = @import("store_memory.zig").MemoryStore;
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;

/// What the scenario leaves for the host to read: the rendered diagnostics, back to back.
pub const report_bytes_max: u32 = 2 * constants.diag_output_bytes_max;

/// The step a failed run stopped at; 0 is success. The host compares it with `Step.done`.
pub const Step = enum(u32) {
    done = 0,
    put,
    watch_sees_put,
    lease_attached,
    lease_expired_by_clock,
    watch_sees_expiry,
    compaction_refuses_old_watch,
    runtime_types,
    render_zc,
    render_zbx,
};

pub const Report = struct {
    /// The first step that did not hold, `done` if none.
    failed: Step = .done,
    bytes: [report_bytes_max]u8 = undefined,
    len: u32 = 0,

    pub fn text(report: *const Report) []const u8 {
        assert(report.len <= report_bytes_max);
        return report.bytes[0..report.len];
    }

    fn append(report: *Report, piece: []const u8) void {
        assert(report.len + piece.len <= report_bytes_max);
        @memcpy(report.bytes[report.len..][0..piece.len], piece);
        report.len += @intCast(piece.len);
    }
};

const Failure = error{StepFailed};

/// Records the step and fails if `ok` is false. The scenario is a sequence of such checks.
fn check(report: *Report, step: Step, ok: bool) Failure!void {
    if (ok) return;
    report.failed = step;
    return error.StepFailed;
}

/// Runs the scenario with `gpa` for the store's own memory. Returns normally in both outcomes:
/// the verdict is `report.failed`. A violated assertion inside the core is still a crash.
pub fn run(gpa: Allocator, report: *Report) void {
    report.* = .{};
    scenario(gpa, report) catch {
        assert(report.failed != .done);
        return;
    };
    assert(report.failed == .done);
}

fn scenario(gpa: Allocator, report: *Report) Failure!void {
    var manual: ManualClock = .{};
    const memory = gpa.create(MemoryStore) catch return fail(report, .put);
    defer gpa.destroy(memory);
    memory.init(gpa, manual.clock());
    defer memory.deinit();
    const s = memory.interface();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try put_and_watch(report, s, arena, &diag);
    try lease_lapses(report, s, arena, &manual, &diag);
    try compaction_refuses(report, s, &diag);
    try render_diagnostics(report, &diag);
}

fn fail(report: *Report, step: Step) Failure {
    report.failed = step;
    return error.StepFailed;
}

fn put_and_watch(report: *Report, s: store.Store, arena: Allocator, diag: *Diag) Failure!void {
    const put: store.Op = .{ .put = .{ .key = "/services/hello", .value = "{\"v\":1}" } };
    const written = s.txn(.{ .on_success = &.{put} }, diag) catch return fail(report, .put);
    try check(report, .put, written.succeeded);
    try check(report, .put, written.revision == 1);

    var watch = s.watch(.{ .prefix = "/", .from_revision = 1 }, diag) catch
        return fail(report, .watch_sees_put);
    defer watch.close();
    const batch = watch.next(arena, 0, diag) catch return fail(report, .watch_sees_put);
    try check(report, .watch_sees_put, batch.events.len == 1);
    try check(report, .watch_sees_put, batch.events[0].kind == .put);
    try check(report, .watch_sees_put, std.mem.eql(u8, batch.events[0].kv.key, "/services/hello"));
}

/// A node key on a lease; the injected clock passes the lease's ttl; the store reaps it and a
/// watch opened before the lapse sees the delete under one revision.
fn lease_lapses(
    report: *Report,
    s: store.Store,
    arena: Allocator,
    manual: *ManualClock,
    diag: *Diag,
) Failure!void {
    const lease = s.lease_grant(1000, diag) catch return fail(report, .lease_attached);
    const node: store.Op = .{ .put = .{ .key = "/nodes/n1", .value = "{}", .lease = lease.id } };
    const written = s.txn(.{ .on_success = &.{node} }, diag) catch
        return fail(report, .lease_attached);
    var watch = s.watch(.{ .prefix = "/nodes/", .from_revision = written.revision + 1 }, diag) catch
        return fail(report, .lease_attached);
    defer watch.close();
    const listed = s.lease_list(arena, diag) catch return fail(report, .lease_attached);
    try check(report, .lease_attached, listed.len == 1);
    try check(report, .lease_attached, listed[0].remaining_ms == 1000);
    try check(report, .lease_attached, listed[0].keys.len == 1);

    manual.advance(999);
    const early = s.expire_leases(diag) catch return fail(report, .lease_expired_by_clock);
    try check(report, .lease_expired_by_clock, early == 0);
    manual.advance(2);
    const reaped = s.expire_leases(diag) catch return fail(report, .lease_expired_by_clock);
    try check(report, .lease_expired_by_clock, reaped == 1);

    const batch = watch.next(arena, 0, diag) catch return fail(report, .watch_sees_expiry);
    try check(report, .watch_sees_expiry, batch.events.len == 1);
    try check(report, .watch_sees_expiry, batch.events[0].kind == .delete);
    const gone = s.get(arena, "/nodes/n1", null, diag) catch
        return fail(report, .watch_sees_expiry);
    try check(report, .watch_sees_expiry, gone.kv == null);
}

/// Compacts, then asks for history below the point: the refusal is a coded diagnostic that the
/// caller renders, as the server will for a 410.
fn compaction_refuses(report: *Report, s: store.Store, diag: *Diag) Failure!void {
    const head = s.status(diag) catch return fail(report, .compaction_refuses_old_watch);
    s.compact(head.revision, diag) catch return fail(report, .compaction_refuses_old_watch);
    const opened = s.watch(.{ .prefix = "/", .from_revision = 1 }, diag);
    if (opened) |_| {
        return fail(report, .compaction_refuses_old_watch);
    } else |err| {
        try check(report, .compaction_refuses_old_watch, err == error.Compacted);
    }
    try check(report, .compaction_refuses_old_watch, diag.code != null);
    try check(report, .compaction_refuses_old_watch, diag.code.? == .E0203);
}

/// A ZC- diagnostic from the collector the store just filled, and a ZBX- one as it arrives from
/// a node (parsed from its JSON, with a member this version does not know), both rendered with
/// each product's own commands and links, and carried in the runtime's `ExitReason`.
fn render_diagnostics(report: *Report, diag: *Diag) Failure!void {
    var own: Diagnostic = undefined;
    diag_mod.to_diagnostic(&own, diag);
    diag.reset();
    var foreign: Diagnostic = undefined;
    const wire = "{\"code\":\"ZBX-E0501\",\"severity\":\"error\",\"blame\":\"user\"," ++
        "\"summary\":\"image not found\",\"causes\":[\"digest b3:00ff is not in this store\"]," ++
        "\"while\":[],\"context\":{},\"fixes\":[{\"sentence\":\"check the digest\"," ++
        "\"command\":null}],\"added_later\":{\"x\":[1,2]}," ++
        "\"omitted\":{\"causes\":0,\"while\":0,\"context\":0,\"fixes\":0}}";
    zigbox.diagnostic.parse_json(&foreign, wire) catch return fail(report, .render_zbx);
    foreign.set_docs(&zigbox.product.Product.zbx);

    const exit: runtime.ExitReason = .{ .start_failed = foreign };
    try check(report, .runtime_types, exit.start_failed.code.len == "ZBX-E0501".len);

    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    report.append(diag_mod.render(&own, .text, false, &buffer));
    const own_hint = std.mem.indexOf(u8, report.text(), "zcube explain E0203");
    try check(report, .render_zc, own_hint != null);
    const mark = report.len;
    report.append(diag_mod.render(&exit.start_failed, .text, false, &buffer));
    const shown = report.text()[mark..];
    try check(report, .render_zbx, std.mem.indexOf(u8, shown, "zbx explain E0501") != null);
}

const testing = std.testing;

test "the scenario passes natively, and what it renders names each product's own command" {
    // Goal: the scenario that `zig build wasm` runs in a host is correct before it is compiled
    // for one. Method: run it with the testing allocator (which also proves the store leaks
    // nothing) and read the report.
    var report: Report = undefined;
    run(testing.allocator, &report);
    try testing.expectEqual(Step.done, report.failed);
    const text = report.text();
    try testing.expect(std.mem.indexOf(u8, text, "error[ZC-E0203]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "zcube explain E0203") != null);
    const own_page = "zigbox.github.io/zigcube/errors/E0203.html";
    try testing.expect(std.mem.indexOf(u8, text, own_page) != null);
    try testing.expect(std.mem.indexOf(u8, text, "error[ZBX-E0501]: image not found") != null);
    try testing.expect(std.mem.indexOf(u8, text, "zbx explain E0501") != null);
    const foreign_page = "zigbox.github.io/zigbox/errors/E0501.html";
    try testing.expect(std.mem.indexOf(u8, text, foreign_page) != null);
}
