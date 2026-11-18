//! Test-only: a barrier immediately before a node's registration transaction (#237, the
//! zigcube-jepsen stale-registration test). Shell code: files and a sleep. It exists only in a
//! server built with `-Dregister-barrier=true` and armed by `ZCUBE_TEST_REGISTER_BARRIER=DIR`;
//! `zig build`, `dist` and `release` leave it out (`build_options.register_barrier` is false and
//! `zcube_server.zig` refuses the variable).
//!
//! The protocol, all files in DIR:
//! - The test creates `arm-<node>`. The next registration transaction of `<node>` (a put of
//!   `/nodes/<node>` on a lease) removes it, creates `held-<node>-<lease>`, and waits.
//! - The test creates `release-<node>-<lease>`; the transaction then runs as it would have.
//!   Without a release it runs after `wait_ms_max`, so a lost test cannot wedge a server.
//! - The barrier writes `done-<node>-<lease>`: `succeeded <0|1> revision <N> at_ms <unix ms>`.
//!   The API's checks (the lease order of #237) ran before the barrier; the transaction's compare
//!   on the key's revision runs after it, so a registration released after a newer one took the
//!   key must come back refused (`succeeded 0`).
//!
//! Only the armed registration waits: the agent's next attempt, on a newer lease, passes.

const std = @import("std");
const assert = std.debug.assert;
const diag_mod = @import("diag.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Diag = diag_mod.Diag;
const Store = store.Store;

/// The longest a held registration waits for its release.
pub const wait_ms_max: u64 = 300_000;
const poll_ms: u64 = 10;

/// The one barrier of the process: a store's vtable functions get the inner store's context, so
/// the wrapped `txn` finds its state here. Set once, before any request is served.
var installed: ?*Barrier = null;

pub const Barrier = struct {
    inner: Store,
    vtable: Store.VTable,
    io: std.Io,
    /// The directory of the protocol's files; owned by the caller and outliving the server.
    dir: []const u8,

    /// `inner` with its `txn` behind the barrier. Call once per process.
    pub fn install(barrier: *Barrier, inner: Store, io: std.Io, dir: []const u8) Store {
        assert(installed == null);
        assert(dir.len > 0);
        barrier.* = .{ .inner = inner, .vtable = inner.vtable.*, .io = io, .dir = dir };
        barrier.vtable.txn = txn;
        installed = barrier;
        return .{ .context = inner.context, .vtable = &barrier.vtable };
    }

    fn txn(
        context: *anyopaque,
        request: store.TxnRequest,
        diag: *Diag,
    ) store.Error!store.TxnResult {
        const barrier = installed.?;
        assert(context == barrier.inner.context);
        const registration = registered(request) orelse
            return barrier.inner.vtable.txn(context, request, diag);
        if (!barrier.take_arm(registration.node)) {
            return barrier.inner.vtable.txn(context, request, diag);
        }
        barrier.hold(registration);
        const result = barrier.inner.vtable.txn(context, request, diag);
        const succeeded = if (result) |done| done.succeeded else |_| false;
        const revision = if (result) |done| done.revision else |_| 0;
        barrier.note(registration, "done", succeeded, revision);
        return result;
    }

    const Registration = struct { node: []const u8, lease: store.LeaseId };

    /// The node a transaction registers: a put of `/nodes/<node>` on a lease.
    fn registered(request: store.TxnRequest) ?Registration {
        for (request.on_success) |op| {
            const put = switch (op) {
                .put => |put| put,
                else => continue,
            };
            if (!std.mem.startsWith(u8, put.key, records.prefix_nodes)) continue;
            if (put.lease == store.lease_none) continue;
            const node = put.key[records.prefix_nodes.len..];
            if (node.len == 0 or std.mem.indexOfScalar(u8, node, '/') != null) continue;
            return .{ .node = node, .lease = put.lease };
        }
        return null;
    }

    fn take_arm(barrier: *Barrier, node: []const u8) bool {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}/arm-{s}", .{ barrier.dir, node }) catch
            return false;
        std.Io.Dir.cwd().deleteFile(barrier.io, path) catch return false;
        return true;
    }

    fn hold(barrier: *Barrier, registration: Registration) void {
        barrier.note(registration, "held", false, 0);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}/release-{s}-{d}", .{
            barrier.dir, registration.node, registration.lease,
        }) catch return;
        var waited_ms: u64 = 0;
        while (waited_ms < wait_ms_max) : (waited_ms += poll_ms) {
            if (std.Io.Dir.cwd().access(barrier.io, path, .{})) |_| return else |_| {}
            barrier.io.sleep(.fromMilliseconds(poll_ms), .awake) catch return;
        }
    }

    /// Writes `<what>-<node>-<lease>`; a file that cannot be written is left out (the test then
    /// times out, which is its failure to report).
    fn note(
        barrier: *Barrier,
        registration: Registration,
        what: []const u8,
        succeeded: bool,
        revision: store.Revision,
    ) void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}-{s}-{d}", .{
            barrier.dir, what, registration.node, registration.lease,
        }) catch return;
        const at_ms = std.Io.Clock.real.now(barrier.io).toMilliseconds();
        var data_buffer: [96]u8 = undefined;
        const data = std.fmt.bufPrint(&data_buffer, "succeeded {d} revision {d} at_ms {d}\n", .{
            @intFromBool(succeeded), revision, at_ms,
        }) catch unreachable; // 96 bytes hold three numbers of at most 20 digits and the words.
        std.Io.Dir.cwd().writeFile(barrier.io, .{ .sub_path = path, .data = data }) catch {};
    }
};
