//! The teeth tests of the TLS server fuzzer. They live apart from `tls_server_fuzz.zig` so that
//! they run in `zig build mtls-teeth` only (`src/mtls_teeth.zig` imports this file,
//! `src/tests.zig` does not).

const std = @import("std");
const testing = std.testing;
const fuzz = @import("tls_server_fuzz.zig");
const tls_server = @import("tls_server.zig");

/// Runs seeds 1, 2, ... with `fault` on until one connects falsely; fails if none of the first
/// `seeds_max` does.
fn expect_false_connect(fault: tls_server.TestFault) !void {
    tls_server.set_test_fault(fault, true);
    defer tls_server.set_test_fault(fault, false);
    const seeds_max = 4000;
    var seed: u64 = 1;
    // Stops at the first: the test proves "at least one within `seeds_max` seeds".
    while (seed <= seeds_max) : (seed += 1) {
        var refused = false;
        if (try fuzz.run_once(seed, &refused)) return;
    }
    std.debug.print("teeth: no false connect with {t} off in {d} seeds\n", .{ fault, seeds_max });
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
