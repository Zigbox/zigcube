//! The launch directory of one Zigbox container: what `ZigboxRuntime` leaves for the supervisor
//! (`zcube-agent supervise-zigbox`) and what the supervisor leaves for it. C2 slice 1.
//!
//! Zigbox's own run record exists only once the container is created, and a pull of a large
//! image takes minutes before that. In between the replica is `starting`, and the only evidence
//! is this directory, `<state>/zigbox/<name>/`:
//!
//!   - `spec.json`: what to run (the agent writes it before it starts the supervisor);
//!   - `lock`: held (`flock`) by the supervisor for as long as it lives;
//!   - `failed.json`: the Zigbox diagnostic (one JSON line) when the supervisor could not start
//!     the container, written before it exits. No Zigbox run record exists in that case.
//!
//! `phase` turns the three into one answer. Shell code (files), but every decision is in `phase`
//! and `decide`, which take values.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const files = @import("fake_files.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Diagnostic = diag_mod.Diagnostic;

pub const dir_name = "zigbox";
pub const file_spec = "spec.json";
pub const file_lock = "lock";
pub const file_failed = "failed.json";
pub const file_supervisor = "supervisor.pid";

pub const Pair = files.Pair;

/// How the supervisor asks the swarm for a tree the node lacks, before it pulls: it runs
/// `<exe> fetch ...` (`fetch_cli.zig`) against the node's Zigbox store. Borrowed.
pub const Fetch = struct {
    exe: []const u8,
    node: []const u8,
    state_dir: []const u8,
    /// `HOST:PORT` of the server, from which the peers are read; empty: none.
    server: []const u8 = "",
    /// `HOST:PORT` of the registry; empty: peers only.
    registry: []const u8 = "",
};

/// What the supervisor is to run. `tree` is the locked Zigbox tree digest (`b3:...`, the
/// service's `image`); `reference` is the OCI reference to pull it from, empty if the node has
/// none for it.
pub const Spec = struct {
    name: []const u8,
    tree: []const u8,
    reference: []const u8,
    /// Null: no peers to ask. Set only with a digest-pinned reference (its manifest is the one
    /// the fetched image record is held to).
    fetch: ?Fetch = null,
    command: []const []const u8,
    env: []const Pair,
    labels: []const Pair,
    cpu_millis: ?u32 = null,
    memory_bytes: ?u64 = null,
    pids: ?u32 = null,
    /// `HOST:PORT` of the job's one relay upstream; empty: none. The supervisor asks Zigbox for a
    /// listener on the container's loopback and relays it there (B3 slice 4, `relay.zig`).
    relay: []const u8 = "",
    /// The upstream's TLS server name (B4); empty for B3's plain upstream. The zigbox
    /// supervisor does not speak TLS to a relay until B4 slice 4, so it refuses any relay that
    /// names one rather than connect in plaintext (fail closed, #228).
    relay_server_name: []const u8 = "",
    /// A Debug build's test-only plain upstream (`relay_tls.plain_allowed`).
    relay_plain: bool = false,
    /// The job's DSSE envelopes that counted under the node's policy (B5), one line each: the
    /// supervisor keeps them in the node's Zigbox store before the start when the node's `zbx`
    /// policy asks (`import_signatures`). Empty: nothing to keep.
    signatures: []const []const u8 = &.{},
    /// `host.time_now()` (seconds) when the agent decided to start it: a Zigbox record older than
    /// this belongs to an earlier container of the same name.
    launched: u64,
};

/// Where a launch is, before (or without) a Zigbox record.
pub const Phase = union(enum) {
    /// No launch directory, or no spec in it: not a container of ours.
    absent,
    /// The supervisor lives: pulling, preparing, or running.
    working,
    /// The supervisor ended without a record and left this diagnostic line.
    failed: []const u8,
    /// The supervisor is gone and left nothing.
    gone,
};

pub fn container_dir(io: std.Io, root: Dir, name: []const u8) ?Dir {
    return root.openDir(io, name, .{}) catch null;
}

/// The directory that holds every launch directory, made if need be.
pub fn open_root(io: std.Io, state: Dir) error{StateDirFailed}!Dir {
    state.createDirPath(io, dir_name) catch return error.StateDirFailed;
    return state.openDir(io, dir_name, .{ .iterate = true }) catch error.StateDirFailed;
}

/// Writes the spec for a new launch of `spec.name`, clearing what an earlier one left. The
/// spec is the last thing written, so a directory with a spec is complete.
pub fn write_spec(io: std.Io, root: Dir, spec: *const Spec) files.WriteError!void {
    assert(spec.name.len > 0);
    assert(spec.tree.len > 0);
    root.createDirPath(io, spec.name) catch return error.WriteFailed;
    const dir = root.openDir(io, spec.name, .{}) catch return error.WriteFailed;
    defer dir.close(io);
    dir.deleteFile(io, file_spec) catch {}; // Absent is fine; a new one follows.
    dir.deleteFile(io, file_failed) catch {};
    dir.deleteFile(io, file_supervisor) catch {}; // The last launch's; this one writes its own.
    const lock = dir.createFile(io, file_lock, .{ .truncate = false }) catch
        return error.WriteFailed;
    lock.close(io);
    try files.write_json(io, dir, file_spec, spec.*);
}

pub fn read_spec(io: std.Io, dir: Dir, arena: Allocator) files.ReadError!Spec {
    return files.read_json(Spec, io, dir, file_spec, arena);
}

pub fn remove(io: std.Io, root: Dir, name: []const u8) void {
    root.deleteTree(io, name) catch {}; // A leftover is found and replaced by the next launch.
}

/// True if a supervisor holds the lock. Taking it ourselves, to test, lets go at once.
pub fn supervisor_alive(io: std.Io, dir: Dir) bool {
    const file = dir.createFile(io, file_lock, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| return err == error.WouldBlock;
    file.close(io);
    return false;
}

pub fn phase(io: std.Io, dir: Dir, arena: Allocator) Phase {
    if (!files.exists(io, dir, file_spec)) return .absent;
    if (supervisor_alive(io, dir)) return .working;
    if (files.read_bytes(io, dir, file_failed, arena)) |line| return .{ .failed = line } else |_| {}
    return .gone;
}

/// What the supervisor does first: take the lock for good. Not closed; the kernel releases it
/// when the process ends, and that is what `supervisor_alive` tests.
pub fn hold_lock(io: std.Io, dir: Dir) error{LockFailed}!void {
    _ = dir.createFile(io, file_lock, .{ .truncate = false, .lock = .exclusive }) catch
        return error.LockFailed;
}

/// Records why the container did not start, as one JSON line.
pub fn write_failed(io: std.Io, dir: Dir, diagnostic: *const Diagnostic) files.WriteError!void {
    var buffer: [constants.fake_file_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    zigbox.diagnostic.write_json(&writer, diagnostic) catch return error.WriteFailed;
    try files.write_atomic(io, dir, file_failed, writer.buffered());
}

/// The diagnostic a `failed.json` line holds, or null if it does not parse.
pub fn parse_failed(out: *Diagnostic, line: []const u8) bool {
    zigbox.diagnostic.parse_json(out, std.mem.trim(u8, line, "\n ")) catch return false;
    return out.code.len > 0;
}

/// `zcube-agent: container NAME did not start: CODE summary: last cause`, one line on stderr.
pub fn log_start_failure(io: std.Io, name: []const u8, failure: *const Diagnostic) void {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print("zcube-agent: container {s} did not start: {s} {s}", .{
        name, failure.code.slice(), failure.summary.slice(),
    }) catch {};
    const causes = failure.causes.slice();
    if (causes.len > 0) writer.print(": {s}", .{causes[causes.len - 1].slice()}) catch {};
    if (writer.end == buffer.len) writer.end -= 1; // A cut line still ends in a newline.
    writer.writeByte('\n') catch {};
    std.Io.File.stderr().writeStreamingAll(io, writer.buffered()) catch {};
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

/// The label pair outlives the call: `sample` returns a spec that points at it.
var sample_labels: [1]Pair = undefined;

fn sample(name: []const u8) Spec {
    sample_labels[0] = .{ "zcube.replica", name };
    return .{
        .name = name,
        .tree = "b3:51aa9c03",
        .reference = "ghcr.io/o/r@sha256:00",
        .command = &.{ "sh", "-c", "true" },
        .env = &.{.{ "K", "v" }},
        .labels = &sample_labels,
        .memory_bytes = 1 << 26,
        .launched = 100,
    };
}

test "a launch directory goes from absent to working to failed or gone" {
    // Goal: the four phases, from the files alone. Method: write a spec; with no lock holder the
    // supervisor is gone; a failure line makes it failed; a held lock makes it working.
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try open_root(io, tmp.dir);
    defer root.close(io);
    try testing.expect(container_dir(io, root, "web-1") == null);

    try write_spec(io, root, &sample("web-1"));
    const dir = container_dir(io, root, "web-1").?;
    defer dir.close(io);
    try testing.expectEqual(Phase.gone, phase(io, dir, arena));

    var diagnostic: Diagnostic = undefined;
    var diag: zigbox.diag.Diag = undefined;
    diag.reset();
    diag.raise(.E0410);
    zigbox.diagnostic.from_diag(&diagnostic, &diag);
    try write_failed(io, dir, &diagnostic);
    const failed = phase(io, dir, arena);
    var parsed: Diagnostic = undefined;
    try testing.expect(parse_failed(&parsed, failed.failed));
    try testing.expectEqualStrings("ZBX-E0410", parsed.code.slice());

    // A new launch of the same name clears the failure.
    try write_spec(io, root, &sample("web-1"));
    try testing.expectEqual(Phase.gone, phase(io, dir, arena));

    const holder = try dir.createFile(io, file_lock, .{ .truncate = false, .lock = .exclusive });
    defer holder.close(io);
    try testing.expectEqual(Phase.working, phase(io, dir, arena));
}

test "a spec survives the round trip" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const root = try open_root(io, tmp.dir);
    defer root.close(io);
    try write_spec(io, root, &sample("web-2"));
    const dir = container_dir(io, root, "web-2").?;
    defer dir.close(io);
    const spec = try read_spec(io, dir, arena_state.allocator());
    try testing.expectEqualStrings("web-2", spec.name);
    try testing.expectEqualStrings("sh", spec.command[0]);
    try testing.expectEqualStrings("v", spec.env[0][1]);
    try testing.expectEqual(@as(?u64, 1 << 26), spec.memory_bytes);
    try testing.expectEqual(@as(?u32, null), spec.pids);
    try testing.expectEqual(@as(u64, 100), spec.launched);
}

test "a failure line that does not parse is not a diagnostic" {
    var parsed: Diagnostic = undefined;
    try testing.expect(!parse_failed(&parsed, "{{{"));
    try testing.expect(!parse_failed(&parsed, ""));
}

/// `sha256:HEX` of a reference pinned by digest (`name@sha256:HEX`), else null.
pub fn manifest_of(reference: []const u8) ?[]const u8 {
    const at = std.mem.lastIndexOfScalar(u8, reference, '@') orelse return null;
    const text = reference[at + 1 ..];
    if (!std.mem.startsWith(u8, text, "sha256:") or text.len != "sha256:".len + 64) return null;
    for (text["sha256:".len..]) |c| {
        if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return null;
    }
    return text;
}

test "a manifest is read from a reference pinned by digest, and from nothing else" {
    const hex: [64]u8 = @splat('a');
    const upper: [64]u8 = @splat('A');
    const pinned = "ghcr.io/o/r@sha256:" ++ hex;
    try testing.expectEqualStrings("sha256:" ++ hex, manifest_of(pinned).?);
    try testing.expect(manifest_of("ghcr.io/o/r:latest") == null);
    try testing.expect(manifest_of("ghcr.io/o/r@sha256:00") == null);
    try testing.expect(manifest_of("ghcr.io/o/r@sha256:" ++ upper) == null);
    try testing.expect(manifest_of("") == null);
}
