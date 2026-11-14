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
    // `secure` keeps its own copy; this one is not left on the stack.
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key.secret_key));
    relay.secure(tls, key, dir.handle) catch return "there was no memory for the run's key";
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
