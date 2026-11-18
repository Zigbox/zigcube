# C5 slice 1: the public path's bounds, codes and test layout

*Decided 2026-11-18, by C5 slice 1. The implementer's assumptions, for the supervisor's review.*

**Bounds (`src/constants.zig`, "The edge's public TLS mode").** New, and used only by the public
path and `edge_host.zig`; nothing user-facing reads them yet (no API, no CLI), so no existing
bound, limit or default changed.

- `edge_host_bytes_max` 253 and `edge_host_label_bytes_max` 63: RFC 1035 without the trailing dot,
  as the brief's "Host names" says.
- `edge_chain_certificates_max` 3: the leaf and up to two intermediates (Let's Encrypt sends one;
  a cross-signed chain two). B7's `tls_chain_certificates_max` (2) is unchanged.
- `edge_certificate_bytes_max` 4096 and `edge_chain_bytes_max` 8192: a Let's Encrypt ECDSA leaf
  with 100 names is under 4 KiB, an intermediate about 1.3 KiB; with the rest of the flight the
  chain fits one 16 KiB record, so the server's flight stays within one record buffer.
- `edge_hosts_max` 1024: rows of one listener's `PublicTable`.

When slice 4b exposes `public` hosts, the supervisor may want `edge_hosts_max` raised or tied to
a cluster limit; it is one constant.

**No new codes.** A refused public ClientHello is ZC-E0818 (the ClientHello is refused), with the
alert the brief names (`unrecognized_name`, `no_application_protocol`) or `handshake_failure` for
x25519 without a share, and a cause naming the offence. The brief's counter
`edge_handshakes_refused{reason}` belongs to the edge process (slice 4b); the server's refusal
already carries the reason. `edge_host` returns an error per broken rule with `describe`; the
apply-time code ZC-E0715 is registered when apply uses it (slice 4a), after the owner's yes.

**`server_name()` once the chain is picked.** A refusal after that point (ALPN, early data) names
the host, so an operator sees which host a refused browser asked for.

**Test layout.** The public path's fuzzer is its own file, `tls_server_public_fuzz.zig`, reusing
`tls_server_fuzz.zig`'s mutations (made `pub`), rather than a mode inside the cluster fuzzer: the
cluster fuzzer's twenty-one knobs and seed ranges, which its teeth depend on, stay as they were.
Tidy's `testclient_importer` allows it. The scripted client gained `.rsa_pss` (a signature list
with no ECDSA) for the refusal row, since its `.ed25519` and `.other` lists both carry
`ecdsa_secp256r1_sha256`. `mtls-teeth` now selects 56 tests (51 + 3 + 2).

**The browser check** (`zig build public-tls-check`) is test-only and not in `check` or CI: it
needs Playwright's Chromium and `certutil`. Its first visit, with an empty NSS store, must fail
with `ERR_CERT_AUTHORITY_INVALID`, so that the second visit's pass is due to the test CA.

Where: `src/constants.zig`, `src/tls_server.zig`, `src/tls_server_public_test.zig`,
`src/tls_server_public_fuzz.zig`, `tools/public_tls_check.mjs`, docs/mtls.md "The public path".
