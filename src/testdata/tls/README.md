# TLS fixtures

`client_hello_chromium.bin`: the first TLS record (a ClientHello, 1,728 bytes) that Chromium
157.0.8103.78 (Playwright's bundled build, headless, Linux) sent to `https://hello.test:PORT/`
on 2026-11-18. Recorded with

    node tools/record_client_hello.mjs --out src/testdata/tls/client_hello_chromium.bin

It offers X25519MLKEM768 and x25519 key shares, ALPN `h2` and `http/1.1`, SNI `hello.test`,
GREASE, ECH GREASE and ecdsa_secp256r1_sha256. The public mode's tests feed it to the server
(`src/tls_server_public_test.zig`).

Firefox and Safari were not recorded: no Firefox build could be installed in the container,
and Safari does not run on Linux. `docs/decisions/2026-11-18-c5-client-hello-fixtures.md`.
