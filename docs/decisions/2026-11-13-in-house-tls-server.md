# The in-house TLS scope widens to a TLS 1.3 server

*Decided 2026-11-13, by the owner, in the B7 brief (`docs/briefs/b7.md`, "Fixed decisions"); recorded by B7 slice 1, as `2026-11-04-in-house-tls-review-before-c6.md` asks.*

That decision accepted the in-house X.509 writer, parser and TLS 1.3 client on a narrow scope. It said any widening needs a decision of its own. B7 serves the API over mTLS (`--listen` with TLS once the CA exists), so Zigcube needs a TLS server. std has none that asks for a client certificate, and the no-third-party-dependencies rule stands.

## What is accepted

`src/tls_server.zig` is the server. It is a pure state machine like the client and shares the client's key schedule (`tls_schedule.zig`), record layer and wire code (`tls_wire.zig`). It has no second copy of either.

The scope stays as narrow as the client's:

- TLS 1.3 only, x25519 only, `TLS_AES_128_GCM_SHA256` only, and Ed25519 only.
- No HelloRetryRequest, no PSK or session tickets, and no early data.
- **Client authentication is always required.** A client with no certificate, or with an empty Certificate, is refused. Nothing gets in any other way.
- Only certificates of this cluster's CA are accepted, of the kind the server is configured for. Slice 1 has the `workload` kind; `node` and `client` come in slice 2.
- The handshake deadline and the record limits are the client's constants. No new constant was added.
- A failed handshake uses the existing codes ZC-E0810 to ZC-E0820 (and ZC-E0809 for a malformed certificate, through `x509.raise`). The failure is logged on the server side, with server-side fix sentences. No code was registered.

## What stays

- The external security review before C6 now covers the server as well as the client.
- Until then the in-tree defences apply to the server too:
  - near-miss tables for the ClientHello and for the client's flight (`tls_server_test.zig`);
  - a teeth test for every security check, in `zig build mtls-teeth`;
  - a seeded fuzzer that damages the client's hello and flight (`tls_server_fuzz.zig`), with teeth of its own (`tls_server_fuzz_teeth.zig`);
  - and later (slice 3) the mtls-interop rows with stock clients against it.
- Any further widening needs another decision. That includes another key type, suite or group, an optional client certificate, or certificates from another CA.
