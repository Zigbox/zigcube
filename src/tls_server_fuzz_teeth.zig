//! The teeth tests of the TLS server fuzzer. They live apart from `tls_server_fuzz.zig` so that
//! they run in `zig build mtls-teeth` only (`src/mtls_teeth.zig` imports this file,
//! `src/tests.zig` does not).

const std = @import("std");
const testing = std.testing;
const fuzz = @import("tls_server_fuzz.zig");
const public_fuzz = @import("tls_server_public_fuzz.zig");
const tls_server = @import("tls_server.zig");

/// Runs seeds 1, 2, ... until one connects falsely with `fault` on; fails if none of the first
/// `seeds_max` does. Each seed also runs with the fault off first and must not connect falsely
/// there, so the tooth bites through the fault and not through a hole in the fuzzer's oracle.
fn expect_false_connect(fault: tls_server.TestFault) !void {
    return expect_false_connect_in(fault, fuzz.run_once);
}

fn expect_false_connect_in(
    fault: tls_server.TestFault,
    run_once: *const fn (u64, *bool) anyerror!bool,
) !void {
    defer tls_server.set_test_fault(fault, false);
    const seeds_max = 4000;
    var seed: u64 = 1;
    // Stops at the first: the test proves "at least one within `seeds_max` seeds".
    while (seed <= seeds_max) : (seed += 1) {
        var refused = false;
        tls_server.set_test_fault(fault, false);
        if (try run_once(seed, &refused)) {
            std.debug.print("teeth: seed {d} connects falsely with no fault on\n", .{seed});
            return error.TestUnexpectedResult;
        }
        tls_server.set_test_fault(fault, true);
        if (try run_once(seed, &refused)) return;
    }
    std.debug.print("teeth: no false connect with {t} on in {d} seeds\n", .{ fault, seeds_max });
    return error.TestUnexpectedResult;
}

test "teeth: the server fuzzer catches a skipped CertificateVerify check" {
    try expect_false_connect(.certificate_verify);
}

test "teeth: the server fuzzer catches a skipped Finished check" {
    try expect_false_connect(.finished);
}

test "teeth: the server fuzzer catches a skipped chain check" {
    try expect_false_connect(.client_chain);
}

test "teeth: the public fuzzer catches a skipped server name check" {
    try expect_false_connect_in(.sni_check, public_fuzz.run_once);
}

test "teeth: the public fuzzer catches a skipped ALPN check" {
    try expect_false_connect_in(.alpn_check, public_fuzz.run_once);
}

test "teeth: the public fuzzer catches a skipped Finished check" {
    // The public path's only proof that the client holds the handshake keys.
    try expect_false_connect_in(.finished, public_fuzz.run_once);
}
