# The redaction harness, and what slice 2's redaction test covers

*Decided 2026-11-18, by the slice (C5 slice 2).*

- `src/testing/redaction.zig` (test-only) finds a planted secret of at least 8 bytes in raw bytes,
  hex in either case, and base64 standard or URL-safe, padded or not, inside a longer encoded
  string at any alignment (the encoded "core" of the secret at each of the three shifts). A
  failure names the output, the form and the offset, never the secret.
- Slice 2 plants a record sealed with the server's own key over a known plaintext and checks
  `/v1/list` of the whole keyspace, a watch from revision 1, `/v1/status`, and ZC-E0824's text,
  for both the sealing key and the plaintext; W0808's text for the new key. `zcube bundle` fetches
  `/v1/list`, `/v1/status` and `/v1/why`; the first two are checked here, and `/v1/why` is
  checked by the slice that first lets it explain an edge or certificate record (3b or 4a). Logs, failure records and the
  console get their checks with the slices that put key-bearing data near them (3b, 4a), as the
  brief says.

Where: `docs/sealing.md`, `src/testing/redaction.zig`, `src/server_test.zig`.
