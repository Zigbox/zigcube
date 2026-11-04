//! The registry fallback of a Zigbox fetch (C2 slice 8): when no peer has the tree, the image is
//! pulled from its OCI registry with Zigbox's own `pull`, which fetches and verifies the blobs,
//! flattens the layers into the store and writes the image record. Shell code: network, files and
//! a namespace child, all inside `pull`.
//!
//! The reference is the assignment's, pinned by digest (docs/keys.md `source`). What a pull gave
//! is held to the assignment again: the manifest digest must be the expected manifest and the
//! tree must be the digest the fetch was asked for. Anything else is `Mismatch` and the caller
//! reports the tree as unavailable; the store keeps what `pull` wrote, which a later gc collects.
//!
//! Not tested here: a pull needs a registry. The glue is compiled; `zigbox-smoke` runs it.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");

const Allocator = std.mem.Allocator;
const Digest = zigbox.store.Digest;
const Sha256 = @FieldType(zigbox.store.image_peer.Options, "expected_manifest");
const pull = zigbox.pull;
const Facts = @typeInfo(@typeInfo(@TypeOf(pull.pull)).@"fn".param_types[1].?).pointer.child;

pub const Error = error{ OutOfMemory, Failed, Mismatch };

/// Bytes of one blob and how it came, as `pull` saw it: the figures Z5 asks the agent's `/pulls`
/// record to carry.
pub const Blob = struct {
    digest: Sha256,
    bytes: u64,
    outcome: pull.BlobOutcome,
};

pub const Pulled = struct {
    tree: Digest,
    manifest: Sha256,
    /// The first `blob_count` entries: the configuration, then the layers.
    blobs: [blobs_max]Blob,
    blob_count: u32,

    const blobs_max = @typeInfo(@FieldType(pull.Result, "blobs")).array.len;
};

/// Pulls `reference` into the store `environ` locates and checks the result against `tree` and
/// `manifest`. `diag` holds the coded failure when the answer is `Failed`.
pub fn pull_image(
    allocator: Allocator,
    environ: std.process.Environ,
    reference: []const u8,
    tree: Digest,
    manifest: Sha256,
    diag: *zigbox.diag.Diag,
) Error!Pulled {
    const memory = try allocator.create(zigbox.host_real.HostReal);
    defer allocator.destroy(memory);
    const network = try allocator.create(NetworkMemory);
    defer allocator.destroy(network);
    network.init();
    memory.* = .{ .environ = environ, .network_memory = network };
    const facts = try allocator.create(Facts);
    defer allocator.destroy(facts);
    const workspace = try allocator.create(pull.Workspace);
    defer allocator.destroy(workspace);
    const imports = try allocator.create(zigbox.store.import.Workspace);
    defer allocator.destroy(imports);
    const result = try allocator.create(pull.Result);
    defer allocator.destroy(result);
    const request: pull.Request = .{ .reference = reference, .platform = .{}, .mirrors = "" };
    diag.reset();
    pull.pull(memory.interface(), facts, &request, null, workspace, imports, result, diag) catch
        return error.Failed;
    if (!result.tree.eql(tree) or !std.meta.eql(result.manifest_digest, manifest)) {
        return error.Mismatch;
    }
    var pulled: Pulled = .{
        .tree = result.tree,
        .manifest = result.manifest_digest,
        .blobs = undefined,
        .blob_count = result.layer_count + 1,
    };
    for (0..pulled.blob_count) |index| {
        const blob = result.blob(@intCast(index));
        pulled.blobs[index] = .{
            .digest = blob.digest,
            .bytes = blob.bytes,
            .outcome = blob.outcome,
        };
    }
    return pulled;
}

const NetworkMemory = @typeInfo(@typeInfo(
    @FieldType(zigbox.host_real.HostReal, "network_memory"),
).optional.child).pointer.child;
