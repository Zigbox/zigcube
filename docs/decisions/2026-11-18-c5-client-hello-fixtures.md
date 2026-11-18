# Slice 1 records Chromium's ClientHello only

*Decided 2026-11-18, by C5 slice 1.*

The brief asks slice 1 to record the ClientHellos of Chromium, Firefox and Safari as fixtures.
Only Chromium's is recorded (`src/testdata/tls/client_hello_chromium.bin`, Chromium 157, from
Playwright's bundled build, by `tools/record_client_hello.mjs`).

- **Firefox**: the container has no Firefox, and downloading and running a browser build from
  outside the pinned toolchain was refused by the session's permission policy.
- **Safari**: does not run on Linux.

What the fixtures guard is the server's reading of a real browser's hello: GREASE, a hybrid key
share before x25519, ECH GREASE, many extensions. Chromium's covers all of these. Firefox and
Safari hellos can be added later with the same tool on a machine that has them (Playwright's
`firefox` and `webkit` launchers accept the same arguments); each is one file and one test row.

**When and where the rest are recorded** (review of #282; the supervisor may move it): before
slice 4b, the first slice that listens on :443 for real browsers, on a machine that has Firefox
and Safari (a macOS host: Safari runs only there, and Firefox runs there too). Each fixture is
one file under `src/testdata/tls/` and one row in the public tests' fixture table. Until then
Firefox's and Safari's hellos are untested by fixture: a server that refuses one of them would
first show as a failure on that browser in 4b's `edge-smoke` or the C5 demo, not in `check`.

Where: `src/testdata/tls/README.md`, `src/tls_server_public_test.zig`.
