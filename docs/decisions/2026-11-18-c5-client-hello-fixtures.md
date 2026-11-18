# Slice 1 records Chromium's ClientHello only

*Decided 2026-11-18, by C5 slice 1.*

The brief asks slice 1 to record the ClientHellos of Chromium, Firefox and Safari as fixtures.
Only Chromium's is recorded (`fixtures/tls/client_hello_chromium.bin`, Chromium 157, from
Playwright's bundled build, by `tools/record_client_hello.mjs`).

- **Firefox**: the container has no Firefox, and downloading and running a browser build from
  outside the pinned toolchain was refused by the session's permission policy.
- **Safari**: does not run on Linux.

What the fixtures guard is the server's reading of a real browser's hello: GREASE, a hybrid key
share before x25519, ECH GREASE, many extensions. Chromium's covers all of these. Firefox and
Safari hellos can be added later with the same tool on a machine that has them (Playwright's
`firefox` and `webkit` launchers accept the same arguments); each is one file and one test row.

Where: `fixtures/tls/README.md`, `src/tls_server_public_test.zig`.
