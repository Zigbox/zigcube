//! Test root of `zig build mtls-teeth`: only the tests whose name starts with `teeth:` in the
//! files that hold the mTLS checks. Each turns one security check off (`x509.set_test_fault`,
//! `tls_client.set_test_fault`) and passes only if the matching test then fails, so this step
//! passes only if every check has teeth. `zig build test` runs them too; this is the named gate.

test {
    _ = @import("peer_test.zig");
    _ = @import("tls_client_test.zig");
    _ = @import("tls_fuzz.zig");
    _ = @import("x509_fuzz.zig");
}
