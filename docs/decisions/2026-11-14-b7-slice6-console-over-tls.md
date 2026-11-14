# B7 slice 6: the console and the harnesses over TLS

*Decided 2026-11-14. The owner approved the slice. The cut in part 1 is the slice's
conservative choice and is on the **owner list**: the supervisor gave no answer within 20
minutes.*

## The slice

The owner approved adding slice 6 to B7 (docs/briefs/b7.md):

1. The web console works over the TLS listener in a real browser.
2. The harnesses talk to `--listen` as an operator would. `--insecure-listen` stays for
   `zcube local` and for the tests of that listener.

## Part 1, the console in a browser: cut (owner list)

**Evidence.** We captured the ClientHello that Chromium 153.0.8010.12 (the Playwright build in
the container) sends to a raw socket:

- signature_algorithms: ML-DSA (0x0904, 0x0905, 0x0906), ecdsa_secp256r1_sha256,
  rsa_pss_rsae_sha256, rsa_pkcs1_sha256, ecdsa_secp384r1_sha384, rsa_pss_rsae_sha384,
  rsa_pkcs1_sha384, rsa_pss_rsae_sha512, rsa_pkcs1_sha512.
  **There is no ed25519 (0x0807).**
- supported_groups: X25519MLKEM768, x25519, secp256r1, secp384r1. Key shares: X25519MLKEM768
  and x25519.
- Cipher suites include TLS_AES_128_GCM_SHA256. ALPN offers h2 and http/1.1.

The cluster PKI is Ed25519 only: the CA, the server certificate and the CertificateVerify
(B7 fixed decisions). Chromium cannot verify any of it, and cannot sign a CertificateVerify
with an Ed25519 client key. So no browser handshake can succeed against `--listen`, whatever
the server does about ALPN or groups. The PKCS#12 bundle, the SANs and the Playwright test
would all serve a handshake that cannot happen.

**Choices put to the supervisor:**

- **(A), recommended.** A browser-only ECDSA P-256 path:
  - a second, per-cluster P-256 "browser CA";
  - a P-256 server certificate, presented when the ClientHello offers no ed25519;
  - `ca issue-client NAME --scope S --p12 FILE`, which writes a P-256 client certificate in
    PKCS#12;
  - the server accepts either chain, and a CertificateVerify with ecdsa_secp256r1_sha256.

  This needs P-256 signing and verification in the TLS server, which `std.crypto` has.
- **(B).** Move the whole PKI to P-256.
- **(C), conservative.** Cut part 1. The console stays where it is today: `--insecure-listen`
  on loopback, or an operator's own proxy. Record the evidence and do part 2.

There was no answer within 20 minutes, so the slice takes **(C)**. Part 1 is a fresh slice
once the owner picks (A) or (B). Either one changes the fixed PKI decision, which is the
owner's call. `--tls-san NAME_OR_IP` (repeatable, no default) was proposed for the server
certificate's SANs and was not added: it only matters once a browser can handshake.

## Part 2, the harnesses over TLS

`src/harness_tls.zig` (`Pki`) is the shared piece:

- it finds the server's `ca-<hash>.crt` in its state directory;
- it runs `zcube-server ca issue-client NAME --scope S` or `ca issue-node NAME` with the
  server's `--store` and `--state-dir`;
- it returns `--ca/--cert/--key`, exports `ZCUBE_CA/CERT/KEY`, or loads credentials for
  `agent_http.Client.tls`.

| Harness | Over `--listen` now | Notes |
| --- | --- | --- |
| `agent-smoke` | yes | `smoke` admin client; one node certificate per agent |
| `demo-c0` | yes | `demo_host.Config.tls_only`; the `zcube` command gets an `operator` admin certificate through `ZCUBE_CA/CERT/KEY` |
| `demo-c1` | yes | the same; node1's fault proxy forwards TLS bytes unchanged. Step 6 (local mode) drops `ZCUBE_SERVER` and the TLS variables, because `zcube local` serves `--insecure-listen` only |
| `demo-b3` | yes | the guest's agent gets the CA, `node.crt` and `node.key` in `/root/tls` (0600); `guest.sh agent <node> <server> [<tls dir>]` |
| `local-smoke` | no | it exercises only `zcube local`, which is the insecure listener's purpose |
| `demo-b7` | unchanged | it already runs both listeners and tests the insecure one |
| `swarm-smoke` | **no: gap** | see below |

**Gap: the agent's `fetch` child does not speak TLS.**

- `src/fetch_cli.zig`, `Net.http_get`, reads the server's `/v1/list?prefix=/node-store/`
  (peer discovery) as plain HTTP/1.0 on a raw socket.
- Neither runtime passes the child the agent's credentials: not FakeRuntime
  (`fake_runtime.zig`, the `fetch` argv) and not the Zigbox supervisor
  (`zigbox_supervisor.zig`, `fetch_argv`).
- Against `--listen`, the server logs ZC-E0815 for the plain bytes, discovery fails without a
  word, and every node fetches from the registry. Converted, `swarm-smoke` fails with
  "node1: the registry saw 2 tree and 6 chunk requests, expected 1 and 3".
- So C2's peer fetch does not work on a TLS-only server.

The fix belongs to the agent:

- the fetch child takes `--ca/--cert/--key`;
- it reads the server through `api_tls_client`;
- both runtimes pass the flags.

That is next to slice 5's agent-client work, so it is left to a slice of its own.
`swarm-smoke` stays on `--insecure-listen` until then. Converting it is the pattern of
`agent-smoke`: the `pki` and `credentials` fields, `tls_ready` and `agent_tls`.

## CI

The harnesses run in the CI jobs they already had. No browser test was added, so CI gains no
job.
