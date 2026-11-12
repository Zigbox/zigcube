//! Test root of `zig build mtls-teeth`: only the tests whose name starts with `teeth:` in the
//! files that hold the mTLS checks. Each turns one security check off (`x509.set_test_fault`,
//! `tls_client.set_test_fault`) and passes only if the matching test then fails, so this step
//! passes only if every check has teeth. `tls_fuzz_teeth.zig` runs here only; the others also
//! run in `zig build test`.

test {
    _ = @import("peer_test.zig");
    _ = @import("job_cert.zig");
    _ = @import("tls_client_test.zig");
    _ = @import("tls_fuzz.zig");
    _ = @import("tls_fuzz_teeth.zig");
    _ = @import("x509_fuzz.zig");
}
