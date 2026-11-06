//! The mTLS smoke scenario of the control-plane core: the certificates and the TLS client, run
//! where there is no OS (`zig build wasm-check`, docs/wasm.md). A CA issues a server and a
//! workload certificate on a manual clock; both verify against the CA key; a flipped byte, another
//! CA, another name and a time past the window are each refused; and the TLS client, given that
//! trust, writes a ClientHello. It runs natively as a test, so the two can be compared.
//! It needs no socket, no clock and no randomness: every input is fixed.

const std = @import("std");
const assert = std.debug.assert;
const Ed25519 = std.crypto.sign.Ed25519;
const ManualClock = @import("clock.zig").ManualClock;
const peer_ca = @import("peer_ca.zig");
const tls_client = @import("tls_client.zig");
const x509 = @import("x509.zig");

/// The step a failed run stopped at; 0 is success. The host compares it with `done`.
pub const Step = enum(u32) {
    done = 0,
    issue,
    verify_server,
    verify_workload,
    refuse_damaged,
    refuse_other_ca,
    refuse_other_name,
    refuse_expired,
    client_hello,
};

const ttl_ms: u64 = 60 * 60 * 1000;
const cluster = "zc";
const service = "web";
const dns_name = "relay.zc";

var client: tls_client.Client = undefined;

/// Returns the first step that did not hold, `done` if all did.
pub fn run() Step {
    var clock: ManualClock = .{ .ms = 1_700_000_000_000 };
    const ca: peer_ca.Ca = .{
        .key = Ed25519.KeyPair.generateDeterministic(@splat(0xCA)) catch return .issue,
        .revoked = .{},
        .wall = clock.clock(),
    };
    const other = Ed25519.KeyPair.generateDeterministic(@splat(0xCB)) catch return .issue;
    const leaf = Ed25519.KeyPair.generateDeterministic(@splat(5)) catch return .issue;
    var server: x509.Der = .{};
    var workload: x509.Der = .{};
    ca.issue_server_certificate(&server, &.{
        .dns_name = dns_name,
        .subject_key = leaf.public_key.toBytes(),
        .ttl_ms = ttl_ms,
    }) catch return .issue;
    ca.issue_workload_certificate(&workload, &.{
        .cluster = cluster,
        .service = service,
        .subject_key = leaf.public_key.toBytes(),
        .identity = .{ .image_digest = @splat(7), .placement_epoch = 3, .labels = &.{} },
        .ttl_ms = ttl_ms,
    }) catch return .issue;
    const now = clock.ms + 1000;
    const anchor = ca.public();
    const spiffe = "spiffe://" ++ cluster ++ "/service/" ++ service;
    _ = x509.verify(server.slice(), anchor, now, .{ .kind = .server, .name = dns_name }) catch
        return .verify_server;
    _ = x509.verify(workload.slice(), anchor, now, .{ .kind = .workload, .name = spiffe }) catch
        return .verify_workload;
    var damaged = server;
    damaged.bytes[damaged.bytes.len - 1] ^= 1;
    if (verifies(damaged.slice(), anchor, now, .server, dns_name)) return .refuse_damaged;
    const other_anchor = other.public_key.toBytes();
    if (verifies(server.slice(), other_anchor, now, .server, dns_name)) return .refuse_other_ca;
    if (verifies(server.slice(), anchor, now, .server, "other.zc")) return .refuse_other_name;
    if (verifies(server.slice(), anchor, now + 2 * ttl_ms, .server, dns_name)) {
        return .refuse_expired;
    }
    return hello(anchor, now);
}

fn verifies(bytes: []const u8, anchor: [32]u8, now: u64, kind: x509.Kind, name: []const u8) bool {
    _ = x509.verify(bytes, anchor, now, .{ .kind = kind, .name = name }) catch return false;
    return true;
}

fn hello(anchor: [32]u8, now: u64) Step {
    client.init(&.{
        .anchor = anchor,
        .server_name = dns_name,
        .now_ms = now,
        .random = @splat(1),
        .session_id = @splat(2),
        .secret = @splat(3),
    });
    client.start();
    const out = client.output();
    // A TLS record of type handshake (22) whose first message is a ClientHello (1).
    if (out.len < 6 or out[0] != 22 or out[5] != 1) return .client_hello;
    return .done;
}

test "the mTLS smoke scenario holds" {
    // Goal: the scenario the wasm build runs is right natively too. Method: run it.
    try std.testing.expectEqual(Step.done, run());
}
