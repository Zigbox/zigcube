# ZC-E0816 covers stalls; the TLS client's buffer assert, stated correctly

*Decided 2026-11-06, by the owner.*

- **ZC-E0816 covers a handshake that times out and a KeyUpdate answer that stalls**, as well as a
  transport that ends or is cut. This adds no code: the summary, explanation and the `mtls.md`
  row of E0816 say "ended or stalled". It supersedes the "No new diagnostic codes" bullet of
  `2026-11-05-tls-conn.md`, which sent a handshake timeout to E0816 only by implication and
  described E0813 as the page for a refusal, not a stall. The other codes that bullet lists
  (E0813 refusal, E0815 record and key limits, E0810 untrusted server CA, E0820 failing signer)
  stand.
- **The reassembly buffer claim of `2026-11-05-tls-client-part-2.md`** ("the reassembly buffer
  stays 8192 bytes, which holds the largest message the client sends or accepts
  (comptime-asserted)") is corrected. The client sends a Certificate of at most
  `tls_client_certificate_bytes_max` and accepts a handshake message of at most
  `tls_handshake_message_bytes_max`; `constants.zig` asserts at compile time that the first is no
  larger than the second, and that `tls_handshake_flight_bytes_max` (8192) holds two of the
  second. That is what the assert checks, and the buffer claim should be read that way.

Where: `src/diag/codes.zig` (E0816), `docs/mtls.md`, `src/constants.zig`.
