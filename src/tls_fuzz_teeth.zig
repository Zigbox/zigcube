//! The teeth test of the TLS fuzzer. It lives apart from `tls_fuzz.zig` so that it runs in
//! `zig build mtls-teeth` only (`src/mtls_teeth.zig` imports it, `src/tests.zig` does not).

const std = @import("std");
const testing = std.testing;
const fuzz = @import("tls_fuzz.zig");
const tls_client = @import("tls_client.zig");

test "teeth: the property catches a false connect that a later error hides" {
    // Goal: evidence that the check at the moment of `connected` is load-bearing. Method: with
    // the client's CertificateVerify check off, some seed connects to a forged flight and then
    // refuses a record that follows it: the run ends refused, so only the check at the step
    // sees it.
    tls_client.set_test_fault(.certificate_verify, true);
    defer tls_client.set_test_fault(.certificate_verify, false);
    const hidden_min = 8;
    var hidden: u32 = 0;
    var seed: u64 = 1;
    // Stops at the bar: the test proves "at least `hidden_min` within 10,000 seeds".
    while (seed <= 10000 and hidden < hidden_min) : (seed += 1) {
        var refused = false;
        if (try fuzz.run_once(seed, &refused) and refused) hidden += 1;
    }
    testing.expect(hidden >= hidden_min) catch |err| {
        std.debug.print("teeth: only {d} hidden false connects in 10,000 seeds\n", .{hidden});
        return err;
    };
}
