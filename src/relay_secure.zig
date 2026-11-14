//! The run's key for a TLS relay (B4), made by the job's supervisor, the same way under both
//! runtimes (`fake_supervisor.zig`, `zigbox_supervisor.zig`): a fresh Ed25519 pair from
//! `secure_random.zig`, handed to the relay and kept only in this process's memory, and its
//! public half written to `relay.pub` with the run's job, placement epoch and image digest, for
//! the agent to have signed (`agent_relay_certs.zig`). The key is never written anywhere, nor put
//! in the command's environment or directory. Shell code (files, randomness).

const std = @import("std");
const constants = @import("constants.zig");
const files = @import("fake_files.zig");
const job_cert = @import("job_cert.zig");
const relay_module = @import("relay.zig");
const relay_tls = @import("relay_tls.zig");
const runtime = @import("runtime.zig");
const secure_random = @import("secure_random.zig");

/// Makes the run's key, gives it to `relay` and writes `relay.pub` into `dir`, the container's
/// directory. Null when done, else why not (the caller fails the relay with it, ZC-E0702).
/// `random_io` is where randomness comes from; `dir_io` is the `Io` that `dir` was opened with.
pub fn secure(
    random_io: std.Io,
    dir_io: std.Io,
    dir: std.Io.Dir,
    relay: *relay_module.Relay,
    tls: relay_tls.Tls,
    labels: []const files.Pair,
    image: []const u8,
) ?[]const u8 {
    const job = label_of(labels, runtime.label_job) orelse return "the run has no job label";
    const created = label_of(labels, runtime.label_created) orelse
        return "the run has no placement epoch label";
    const epoch = std.fmt.parseInt(u64, created, 10) catch
        return "the run's placement epoch label is not a number";
    if (epoch == 0) return "the run's placement epoch label is 0";
    if (job.len == 0 or job.len > constants.service_name_bytes_max) {
        return "the run's job label is not a job name";
    }
    const digest = job_cert.image_digest(image) orelse
        return "the run's image is not pinned by digest (b3:<64 hex digits>)";
    var seed = secure_random.random_seed(random_io) catch
        return "no randomness for the run's key";
    defer std.crypto.secureZero(u8, &seed);
    var key = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch
        return "the run's key could not be made";
    // The relay's credential keeps the one other copy (zeroed by `Relay.stop`); `secure` and
    // `Credential.init` take the key by pointer, so our code makes no copy on the way, and this
    // one is zeroed before it leaves the stack. What the standard library's Ed25519 leaves in its
    // own frames is out of our reach: the claim is about our copies, not every stack byte.
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key.secret_key));
    relay.secure(tls, &key, dir.handle) catch return "there was no memory for the run's key";
    const request: relay_tls.Request = .{
        .key = key.public_key.toBytes(),
        .epoch = epoch,
        .image_digest = digest,
        .job = job,
    };
    var text: [relay_tls.Request.bytes_max]u8 = undefined;
    files.write_atomic(dir_io, dir, files.file_relay_public, request.format(&text)) catch
        return "relay.pub could not be written";
    return null;
}

fn label_of(labels: []const files.Pair, key: []const u8) ?[]const u8 {
    for (labels) |pair| {
        if (std.mem.eql(u8, pair[0], key)) return pair[1];
    }
    return null;
}

const testing = std.testing;

/// A relay to hand `secure` in a test, with a scratch directory standing for the container's.
const Rig = struct {
    tmp: testing.TmpDir,
    log_path: [:0]u8,
    relay: *relay_module.Relay,

    fn open() !Rig {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(testing.io, &path);
        const log_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/relay.log", .{
            path[0..length],
        }, 0);
        errdefer testing.allocator.free(log_path);
        const upstream: relay_module.Upstream = .{ .host = "127.0.0.1", .port = 9 };
        const relay = try relay_module.Relay.open(testing.allocator, testing.io, upstream, log_path);
        return .{ .tmp = tmp, .log_path = log_path, .relay = relay };
    }

    fn close(rig: *Rig) void {
        rig.relay.stop();
        testing.allocator.free(rig.log_path);
        rig.tmp.cleanup();
    }
};

const test_tls: relay_tls.Tls = .{ .server_name = "broker.botpike.test", .anchor = @splat(7) };
const test_image = "b3:" ++ @as([64]u8, @splat('a'));

test "secure refuses a run whose labels or image cannot name its certificate" {
    // Goal: each label and image check of `secure` refuses with its own reason, before any key
    // is made (no `relay.pub`, no credential). Method: a table of label sets and images, each
    // breaking one check; the boundary job names (one byte, `service_name_bytes_max`) pass the
    // job check, which a row whose next check fails shows.
    const long_job = @as([constants.service_name_bytes_max + 1]u8, @splat('j'));
    const max_job = @as([constants.service_name_bytes_max]u8, @splat('j'));
    const job = runtime.label_job;
    const epoch = runtime.label_created;
    const unpinned = "the run's image is not pinned by digest (b3:<64 hex digits>)";
    const not_a_name = "the run's job label is not a job name";
    const Row = struct { labels: []const files.Pair, image: []const u8, why: []const u8 };
    const rows = [_]Row{
        .{ .labels = &.{.{ epoch, "3" }}, .image = test_image, .why = "the run has no job label" },
        .{
            .labels = &.{.{ job, "job-1" }},
            .image = test_image,
            .why = "the run has no placement epoch label",
        },
        .{
            .labels = &.{ .{ job, "job-1" }, .{ epoch, "x3" } },
            .image = test_image,
            .why = "the run's placement epoch label is not a number",
        },
        .{
            .labels = &.{ .{ job, "job-1" }, .{ epoch, "0" } },
            .image = test_image,
            .why = "the run's placement epoch label is 0",
        },
        .{ .labels = &.{ .{ job, "" }, .{ epoch, "3" } }, .image = test_image, .why = not_a_name },
        .{
            .labels = &.{ .{ job, &long_job }, .{ epoch, "3" } },
            .image = test_image,
            .why = not_a_name,
        },
        .{
            .labels = &.{ .{ job, &max_job }, .{ epoch, "3" } },
            .image = "ghcr.io/o/r@sha256:00",
            .why = unpinned,
        },
        .{ .labels = &.{ .{ job, "j" }, .{ epoch, "3" } }, .image = "b3:abc", .why = unpinned },
    };
    for (rows) |row| {
        var rig = try Rig.open();
        defer rig.close();
        const io = testing.io;
        const why = secure(io, io, rig.tmp.dir, rig.relay, test_tls, row.labels, row.image);
        try testing.expectEqualStrings(row.why, why orelse "accepted");
        try testing.expect(rig.relay.credential == null);
        try testing.expect(!files.exists(io, rig.tmp.dir, files.file_relay_public));
    }
}

test "secure writes relay.pub for the run's own key, and it parses back" {
    // Goal: the round trip the agent depends on: `relay.pub` names the key the relay holds, the
    // run's epoch, image digest and job. Method: secure a relay, parse the file with
    // `Request.parse` and compare it with the relay's credential and the labels.
    var rig = try Rig.open();
    defer rig.close();
    const io = testing.io;
    const labels = [_]files.Pair{
        .{ runtime.label_job, "job-1" },
        .{ runtime.label_created, "42" },
    };
    const why = secure(io, io, rig.tmp.dir, rig.relay, test_tls, &labels, test_image);
    try testing.expectEqualStrings("accepted", why orelse "accepted");
    const credential = rig.relay.credential.?;
    try testing.expectEqualStrings(test_tls.server_name, rig.relay.tls.?.server_name);
    const limit: std.Io.Limit = .limited(relay_tls.Request.bytes_max + 1);
    const file = files.file_relay_public;
    const text = try rig.tmp.dir.readFileAlloc(io, file, testing.allocator, limit);
    defer testing.allocator.free(text);
    const request = relay_tls.Request.parse(text) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &credential.key.public_key.toBytes(), &request.key);
    try testing.expectEqual(@as(u64, 42), request.epoch);
    const digest = job_cert.image_digest(test_image).?;
    try testing.expectEqualSlices(u8, &digest, &request.image_digest);
    try testing.expectEqualStrings("job-1", request.job);
    // The key's seed is nowhere in the file, raw or as hex.
    const seed = credential.key.secret_key.seed();
    try testing.expect(std.mem.indexOf(u8, text, &seed) == null);
    const hex = std.fmt.bytesToHex(seed, .lower);
    try testing.expect(std.mem.indexOf(u8, text, &hex) == null);
}
