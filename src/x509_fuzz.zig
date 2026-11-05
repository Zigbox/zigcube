//! A seeded fuzzer for the X.509 parser and verifier (`x509.zig`, docs/mtls.md): random bytes and
//! damaged certificates. The properties: no crash and no unbounded work; whatever `parse` accepts
//! is exactly what the writer would make (`reencode` returns the same bytes, so the accepted set
//! is the writer's output set and no second encoding of a certificate exists); a certificate that
//! differs from one the CA signed never verifies; and a good certificate is refused out of its
//! window and under another name. A second oracle, `x509_oracle.zig`, decodes every input
//! naively and must agree with `parse` on acceptance and on the fields. Seeds and replay are in
//! `fuzz_seeds.zig`: a failure prints the run's master seed and the failing iteration's seed, each
//! with its replay command; `ZCUBE_FUZZ_ITERATIONS=N` makes a long run, which prints its master
//! seed first. The OpenSSL fixtures of the foreign profile are damaged too.

const std = @import("std");
const x509 = @import("x509.zig");
const t = @import("x509_test.zig");
const constants = @import("constants.zig");
const oracle = @import("x509_oracle.zig");
const seeds = @import("fuzz_seeds.zig");

const testing = std.testing;

const iterations_default = 300;
/// Longer than any certificate, so that an insertion still fits and an oversize input is tried.
const buffer_bytes = constants.x509_cert_bytes_max + 64;

/// Parse must not accept anything the writer would not make, and the naive decoder must agree.
fn expect_canonical(bytes: []const u8) !void {
    const naive = oracle.decode(bytes);
    const parsed = x509.parse(bytes) catch {
        if (naive != null) return error.OracleAcceptedRefused;
        return;
    };
    const verdict = naive orelse return error.OracleRefusedAccepted;
    if (verdict.kind != parsed.kind) return error.OracleDisagrees;
    if (verdict.not_before_ms != parsed.not_before_ms) return error.OracleDisagrees;
    if (verdict.not_after_ms != parsed.not_after_ms) return error.OracleDisagrees;
    if (!std.mem.eql(u8, verdict.name.of(bytes), parsed.name.of(bytes))) {
        return error.OracleDisagrees;
    }
    var again: x509.Der = .{};
    try x509.reencode(&again, bytes, &parsed);
    try testing.expectEqualSlices(u8, bytes, again.slice());
}

const foreign_anchor: [32]u8 = @embedFile("testdata/x509/anchor.pub").*;
const foreign_fixtures = [_][]const u8{
    @embedFile("testdata/x509/minimal.der"),
    @embedFile("testdata/x509/defaults.der"),
};

/// A damaged OpenSSL leaf: never a crash, and never accepted unless it is the original.
fn fuzz_foreign(random: std.Random, buffer: *[buffer_bytes]u8) !void {
    const original = foreign_fixtures[random.uintLessThan(usize, foreign_fixtures.len)];
    @memcpy(buffer[0..original.len], original);
    var length = original.len;
    for (0..random.intRangeAtMost(usize, 1, 3)) |_| length = damage(random, buffer, length);
    const damaged = buffer[0..length];
    var detail: x509.Detail = .{};
    const parsed = x509.parse_profile(original, .foreign_server, &detail) catch unreachable; // A
    // committed fixture that `x509_foreign_test.zig` accepts.
    const now_ms = parsed.not_before_ms + t.hour;
    const name = "broker.botpike.com";
    if (x509.verify_foreign_server(damaged, foreign_anchor, now_ms, name, &detail)) |_| {
        if (!std.mem.eql(u8, damaged, original)) return error.AcceptedDamagedCertificate;
    } else |_| {}
}

/// Applies one random damage to `buffer[0..length]`; returns the new length.
fn damage(random: std.Random, buffer: *[buffer_bytes]u8, length: usize) usize {
    var size = length;
    if (size <= 4) {
        // Too short to damage in place: grow it, so every case below has bytes to work on.
        random.bytes(buffer[size..][0..8]);
        size += 8;
    }
    switch (random.uintLessThan(u8, 7)) {
        0 => buffer[random.uintLessThan(usize, size)] = random.int(u8),
        1 => buffer[random.uintLessThan(usize, size)] ^= @as(u8, 1) << random.int(u3),
        2 => size = random.uintLessThan(usize, size),
        3 => {
            const extra = random.intRangeAtMost(usize, 1, 16);
            random.bytes(buffer[size..][0..extra]);
            size += extra;
        },
        4 => {
            const at = random.uintLessThan(usize, size);
            const extra = random.intRangeAtMost(usize, 1, 8);
            std.mem.copyBackwards(u8, buffer[at + extra .. size + extra], buffer[at..size]);
            random.bytes(buffer[at..][0..extra]);
            size += extra;
        },
        5 => {
            const at = random.uintLessThan(usize, size);
            const gone = @min(random.intRangeAtMost(usize, 1, 8), size - at);
            std.mem.copyForwards(u8, buffer[at .. size - gone], buffer[at + gone .. size]);
            size -= gone;
        },
        else => {
            const a = random.uintLessThan(usize, size - 4);
            const b = random.uintLessThan(usize, size - 4);
            var held: [4]u8 = buffer[a..][0..4].*;
            buffer[a..][0..4].* = buffer[b..][0..4].*;
            buffer[b..][0..4].* = held;
            held = undefined;
        },
    }
    return size;
}

fn good_certificate(random: std.Random, out: *x509.Der) !x509.Kind {
    const kind = random.enumValue(x509.Kind);
    switch (kind) {
        .ca => try t.make_ca(out),
        .workload => try t.make_workload(out),
        .server => try t.make_server(out),
    }
    return kind;
}

/// One iteration: noise, then a good certificate with damage, then the good one's window and name.
fn fuzz_once(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const ca = (try t.ca_pair()).public_key.toBytes();
    var buffer: [buffer_bytes]u8 = undefined;

    const noise = random.uintAtMost(usize, buffer.len);
    random.bytes(buffer[0..noise]);
    try expect_canonical(buffer[0..noise]);

    var certificate: x509.Der = .{};
    const kind = try good_certificate(random, &certificate);
    const original = certificate.slice();
    @memcpy(buffer[0..original.len], original);
    var length = original.len;
    for (0..random.intRangeAtMost(usize, 1, 3)) |_| length = damage(random, &buffer, length);
    const damaged = buffer[0..length];
    try expect_canonical(damaged);
    try fuzz_foreign(random, &buffer);
    if (!std.mem.eql(u8, damaged, original)) {
        const expect: x509.Expect = .{ .kind = kind, .name = null };
        if (x509.verify(damaged, ca, t.now, expect)) |_|
            return error.AcceptedDamagedCertificate
        else |_| {}
    }

    // A flipped bit in the signature or in the subject key still parses; it must not verify.
    const parsed = try x509.parse(original);
    const in_signature = parsed.signature.start + random.uintLessThan(u32, 64);
    const in_key = parsed.public_key.start + random.uintLessThan(u32, 32);
    for ([_]u32{ in_signature, in_key }) |at| {
        @memcpy(buffer[0..original.len], original);
        buffer[at] ^= @as(u8, 1) << random.int(u3);
        const flipped = buffer[0..original.len];
        const expect: x509.Expect = .{ .kind = kind, .name = null };
        if (x509.verify(flipped, ca, t.now, expect)) |_|
            return error.AcceptedDamagedCertificate
        else |_| {}
    }

    // The good certificate: refused outside its window, and under another name.
    const expect: x509.Expect = .{ .kind = kind, .name = null };
    _ = try x509.verify(original, ca, t.now, expect);
    const late = t.now + 3 * t.hour;
    if (x509.verify(original, ca, late, expect)) |_| return error.AcceptedExpired else |_| {}
    const early = t.now - 3 * t.hour;
    if (x509.verify(original, ca, early, expect)) |_| return error.AcceptedNotYetValid else |_| {}
    if (kind != .ca) {
        const other: x509.Expect = .{ .kind = kind, .name = "other.example" };
        if (x509.verify(original, ca, t.now, other)) |_| return error.AcceptedWrongName else |_| {}
    }
}

test "fuzz: damaged and random certificates are refused, never accepted, never crash" {
    // Goal: the parser survives any input, accepts only the writer's own encoding (and agrees
    // with the naive oracle), and no certificate but a CA-signed one verifies. Method: derive each
    // iteration's seed from the run's master seed; random bytes and damaged real certificates go
    // into `parse` and `verify`. A failure prints both seeds and how to replay each.
    try seeds.run("x509 fuzz", iterations_default, fuzz_once);
}

test "teeth: with a check skipped the fuzzer fails, so it can see the bug" {
    // Goal: the properties are not vacuous. Method: switch each test-only fault on in turn and run
    // seeds 1..10; the run must fail for at least one seed per fault.
    const faults = [_]x509.TestFault{ .signature, .window, .name };
    for (faults) |fault| {
        x509.set_test_fault(fault, true);
        defer x509.set_test_fault(fault, false);
        var failed = false;
        for (1..11) |seed| {
            if (fuzz_once(seed)) |_| {} else |_| failed = true;
        }
        try testing.expect(failed);
    }
}
