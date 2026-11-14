//! Test root of `zig build mtls-teeth`: only the tests whose name starts with `teeth:` in the
//! files that hold the mTLS checks. Each turns one security check off (`x509.set_test_fault`,
//! `tls_client.set_test_fault`, `tls_server.set_test_fault`, `server_tls.set_test_fault`,
//! `server_revoked.set_test_fault`, `api_tls_guard.set_test_fault`,
//! `api_scope.set_test_fault`,
//! `agent_api.set_test_fault`) and passes only if the matching test then fails, so this step
//! passes only if every check has teeth.
//! `tls_fuzz_teeth.zig` and `tls_server_fuzz_teeth.zig` run here only; the others also run in
//! `zig build test`.

test {
    _ = @import("peer_test.zig");
    _ = @import("tls_client_test.zig");
    _ = @import("tls_fuzz.zig");
    _ = @import("tls_fuzz_teeth.zig");
    _ = @import("tls_server_fuzz_teeth.zig");
    _ = @import("server_revoked.zig");
    _ = @import("server_tls_test.zig");
    _ = @import("api_tls_guard_test.zig");
    _ = @import("api_scope.zig");
    _ = @import("api_test.zig");
    _ = @import("tls_server_test.zig");
    _ = @import("x509_fuzz.zig");
}
