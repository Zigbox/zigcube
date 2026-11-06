# TLS client part 2: client authentication

Date: 2026-11-05. Slice 5 of `docs/briefs/mtls-client.md`.

## Decisions

- **ZC-E0814 covers three cases,** each with its own fix: the client must authenticate and the
  server did not ask; the request cannot be answered (no Ed25519 in `signature_algorithms`, or in
  `signature_algorithms_cert`); and the server refused the certificate after the client's flight
  (alerts `bad_certificate`, `unsupported_certificate`, `certificate_revoked`,
  `certificate_expired`, `certificate_unknown`, `unknown_ca`, `access_denied`,
  `certificate_required`). A refusal after an empty or absent Certificate is also ZC-E0814, as
  the brief says (this file first said ZC-E0813; corrected in place). Any other alert stays
  ZC-E0813.
- **ZC-E0820 is new: the signer failed.** It is blamed on the environment (the process or device
  holding the key), not on the server, so it is not an E0814 case. Owner: confirm the code.
- **`Config.client_auth` is a union** (`none`, `optional`, `required`, the last two holding the
  Identity), so "must authenticate without a key" cannot be written.
- **The client sends its KeyUpdate by itself** when the write keys reach their limit:
  `seal_application` puts it first. Failure to move on is ZC-E0815.
- **Optional authentication never fails the connection.** With no identity, or a request it cannot
  answer, the client sends an empty Certificate and no CertificateVerify; the server decides.
- **The request context is echoed**, up to 255 bytes. `certificate_authorities` is skipped: the
  client has one chain and sends it.
- **A CertificateRequest with no `signature_algorithms` is malformed** (ZC-E0813). A duplicate
  extension of any type is refused, in the CertificateRequest and in the ServerHello. A second request, or one after the handshake, is refused.
- **The client's Finished covers the client Certificate and CertificateVerify;** the application
  secrets come from the transcript through the server's Finished only (RFC 8446 section 7.1).
- **Constants raised** (`constants.zig`): `tls_output_bytes_max` now holds the change_cipher_spec,
  the client certificate record, the CertificateVerify record and the Finished record (about 2.5
  KiB), because the whole final flight is queued in one step. The reassembly buffer stays 8192
  bytes, which holds the largest message the client sends or accepts (comptime-asserted).
- `send_key_update` and `close_notify` are for the connection layer (slice 6) to rotate sooner or
  end; tested both ways. A test crossing a test-sized record limit is slice 6's.

## Tests that must fail when a check is off

`required_client_auth`, `request_scheme`, `certificate_alert`, `verify_context`, `echo_context`,
`transcript_client_auth` and `finished_omits_auth` each have a teeth test. The fuzzer gives
the server a request (damaged in a third of the runs, with random scheme lists) and the client an
identity at random, checks the peer verified the client's whole flight at the moment of
`connected` (when the request is damaged, only that a required client never connects with an
empty Certificate), and runs a post-handshake script after an intact flight.
