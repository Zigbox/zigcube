# TLS client part 2: client authentication

Date: 2026-11-05. Slice 5 of `docs/briefs/mtls-client.md`.

## Decisions

- **ZC-E0814 covers four cases:** the client must authenticate and the server did not ask; the
  request cannot be answered (no Ed25519 in `signature_algorithms`, or in
  `signature_algorithms_cert`); the signer callback returned nothing; and the server refused the
  certificate after the client's flight (alerts `bad_certificate`, `unsupported_certificate`,
  `certificate_revoked`, `certificate_expired`, `certificate_unknown`, `unknown_ca`,
  `access_denied`, `certificate_required`). Any other alert, or the same alert when no
  certificate was sent, stays ZC-E0813.
- **Optional authentication never fails the connection.** With no identity, or a request it cannot
  answer, the client sends an empty Certificate and no CertificateVerify; the server decides.
- **The request context is echoed**, up to 255 bytes. `certificate_authorities` is skipped: the
  client has one chain and sends it.
- **A CertificateRequest with no `signature_algorithms` is malformed** (ZC-E0813). Duplicate
  `signature_algorithms`, `signature_algorithms_cert` or `certificate_authorities` extensions are
  refused. A second request, or one after the handshake, is refused.
- **The client's Finished covers the client Certificate and CertificateVerify;** the application
  secrets come from the transcript through the server's Finished only (RFC 8446 section 7.1).
- **Constants raised** (`constants.zig`): `tls_output_bytes_max` now holds the change_cipher_spec,
  the client certificate record, the CertificateVerify record and the Finished record (about 2.5
  KiB), because the whole final flight is queued in one step. The reassembly buffer stays 8192
  bytes, which holds the largest message the client sends or accepts (comptime-asserted).
- **The client still never starts a KeyUpdate by itself;** `send_key_update` and `close_notify`
  are for the connection layer (slice 6) and are tested here both ways.

## Tests that must fail when a check is off

`required_client_auth`, `request_scheme`, `certificate_alert`, `verify_context`, `echo_context`,
`transcript_client_auth` and `finished_omits_auth` each have a teeth test. The fuzzer now gives
the server a request and the client an identity at random and checks the peer verified the
client's whole flight at the moment of `connected`.
