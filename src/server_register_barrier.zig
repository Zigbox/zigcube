//! Test-only: a barrier in front of a node's registration request (#237, the zigcube-jepsen
//! stale-registration test). Shell code: files and a sleep. `zcube-server` arms it only when
//! built with `-Dregister-barrier=true` and run with `ZCUBE_TEST_REGISTER_BARRIER=DIR`; any other
//! build ignores the variable and compiles none of this (`zcube_server.zig` imports it behind
//! `build_options.register_barrier`, which `dist` and `release` set false). The unit tests reach
//! it through `server_register_barrier_test.zig`.
//!
//! The protocol, all files in DIR:
//! - The test creates `arm-<node>`. The next `PUT /v1/agent/nodes/<node>` removes it, creates
//!   `held-<node>-<lease>`, and waits.
//! - The test creates `release-<node>-<lease>`; the request then runs as it would have.
//!   Without a release it runs after `wait_ms_max`, so a lost test cannot wedge a server.
//! - The barrier writes `done-<node>-<lease>`: `succeeded <0|1> revision <N> at_ms <unix ms>`.
//!
//! The hold is before the server's write lock (`server_http.Shared.handle`) and before the API
//! reads anything, so other writes go on while a registration is held, a newer registration of
//! the node can land, and the held one, once released, meets the key on the newer lease and comes
//! back refused (`succeeded 0`, ZC-E0205). Only the armed request waits.

const std = @import("std");
const assert = std.debug.assert;
const api_mod = @import("api.zig");
const http = @import("server_http.zig");
const store = @import("store.zig");

/// The longest a held registration waits for its release.
pub const wait_ms_max: u64 = 300_000;
const poll_ms: u64 = 10;
const path_prefix = "/v1/agent/nodes/";

pub const Barrier = struct {
    io: std.Io,
    /// The directory of the protocol's files; owned by the caller and outliving the server.
    dir: []const u8,
    wait_ms: u64 = wait_ms_max,

    pub fn hook(barrier: *Barrier) http.Hook {
        assert(barrier.dir.len > 0);
        return .{ .context = barrier, .before = before, .after = after };
    }

    /// Holds the armed registration; true when it held this request.
    fn before(context: *anyopaque, request: api_mod.Request) bool {
        const barrier: *Barrier = @ptrCast(@alignCast(context));
        const registration = registered(request) orelse return false;
        if (!barrier.take_arm(registration.node)) return false;
        barrier.hold(registration);
        return true;
    }

    fn after(context: *anyopaque, request: api_mod.Request, response: api_mod.Response) void {
        const barrier: *Barrier = @ptrCast(@alignCast(context));
        const registration = registered(request) orelse return; // `before` held it.
        const succeeded = response.status == 200;
        const revision = if (succeeded) revision_of(response.body) else 0;
        barrier.note(registration, "done", succeeded, revision);
    }

    const Registration = struct { node: []const u8, lease: store.LeaseId };

    /// The node and lease of a `PUT /v1/agent/nodes/<node>`; null for any other request and for
    /// a body without a lease (the API refuses that one itself).
    fn registered(request: api_mod.Request) ?Registration {
        if (!std.mem.eql(u8, request.method, "PUT")) return null;
        if (!std.mem.startsWith(u8, request.path, path_prefix)) return null;
        const node = request.path[path_prefix.len..];
        if (node.len == 0 or std.mem.indexOfScalar(u8, node, '/') != null) return null;
        var buffer: [4096]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        const Body = struct { lease: store.LeaseId = store.lease_none };
        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const allocator = fixed.allocator();
        const body = std.json.parseFromSliceLeaky(Body, allocator, request.body, options) catch
            return null;
        if (body.lease == store.lease_none) return null;
        return .{ .node = node, .lease = body.lease };
    }

    fn revision_of(body: []const u8) store.Revision {
        var buffer: [4096]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        const Answer = struct { revision: store.Revision = 0 };
        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const answer = std.json.parseFromSliceLeaky(Answer, fixed.allocator(), body, options) catch
            return 0;
        return answer.revision;
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
        while (waited_ms < barrier.wait_ms) : (waited_ms += poll_ms) {
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
