# B7 slice 6: the console and the harnesses over TLS

*Decided 2026-11-14. The owner approved the slice, and chose the browser path (A) below on the
same day, through the supervisor.*

## The slice

The owner approved adding slice 6 to B7 (docs/briefs/b7.md):

1. The web console works over the TLS listener in a real browser.
2. The harnesses talk to `--listen` as an operator would. `--insecure-listen` stays for
   `zcube local` and for the tests of that listener.

## Part 1, the console in a browser: the owner's decision (A)

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
(B7 fixed decisions). Chromium can neither verify any of it nor sign a CertificateVerify with
an Ed25519 client key. So no browser handshake can succeed against `--listen`, whatever the
server does about ALPN or groups.

**The owner chose (A), a browser-only ECDSA P-256 path** (the alternatives were (B), the whole
PKI on P-256, and (C), cutting part 1). What is approved:

- **A browser CA.** A second per-cluster CA, on P-256, beside the cluster CA.
- **A P-256 server certificate**, presented only when the ClientHello does not list ed25519.
- **`ca issue-client NAME --scope jobs|admin --p12 FILE`.** It issues a P-256 client
  certificate from the browser CA, with the same identity extension, scope and revoked file.
  - The PKCS#12 password comes from a file or from stdin, never from argv.
  - The file is written with mode 0600 and is never overwritten.
- **Client chains of either CA.** The server verifies a client chain of either CA, with
  ecdsa_secp256r1_sha256 for the browser one.
- **`--tls-san NAME_OR_IP`**: repeatable, no default. `--tls-name` stays the first DNS SAN.
- **Only `std.crypto.sign.ecdsa`.** Agents, `zcube` and the relay stay on Ed25519.

What it amends:

- The brief's "Ed25519 only" and its two non-goals, **for the browser path only**.
  docs/briefs/b7.md says so.

Requirements:

- **No signing across paths.** A browser-CA certificate can never be a node certificate, and
  an Ed25519 client certificate never chains to the browser CA. The rule has its own near-miss
  rows and teeth.
- **Every new kind** gets exact-bytes x509 templates, near-miss rows, teeth and fuzz rows.
- **Malleability.** ECDSA signatures are checked for low-S and encoding malleability as std
  does, with a test.

**Status.** Part 1 was built by a later session (branch `claude/b7-slice6-browser`); its
choices are in docs/decisions/2026-11-14-b7-slice6-browser-choices.md and docs/mtls.md,
"Browsers".

## Part 2, the harnesses over TLS

`src/harness_tls.zig` (`Pki`) is the shared piece:

- it finds the server's CA certificate in its state directory, by the server's own names
  (`ca.crt` or `ca-<16 hex>.crt`); only a missing directory means "not yet";
- it runs `zcube-server ca issue-client NAME --scope S` or `ca issue-node NAME` with the
  server's `--store` and `--state-dir`;
- it returns `--ca/--cert/--key`, exports `ZCUBE_CA/CERT/KEY`, or loads credentials for
  `agent_http.Client.tls`.

| Harness | Over `--listen` now | Notes |
| --- | --- | --- |
| `agent-smoke` | yes | `smoke` admin client; one node certificate per agent; checks that plain HTTP gets no answer and that the issued keys are 0600 |
| `demo-c0` | yes | `demo_host.Config.tls_only`; the `zcube` command gets an `operator` admin certificate through `ZCUBE_CA/CERT/KEY`; step 0 checks that plain HTTP gets no answer (`Host.check_tls_only`), so the demo fails if `tls_only` is off |
| `demo-c1` | yes | the same; node1's fault proxy forwards TLS bytes unchanged. Step 6 (local mode) drops `ZCUBE_SERVER` and the TLS variables, because `zcube local` serves `--insecure-listen` only |
| `demo-b1` | yes | the same as `demo-c0` (fix of the slice 6 review); its `zcube job watch` gets the same variables |
| `demo-b3` | yes | the guest's agent gets the CA, `node.crt` and `node.key` in `/root/tls`, each read back as 0600; `guest.sh agent <node> <server> [<tls dir>]` |
| `test-store-faults` failover runs (`src/store_failover.zig`) | yes | a `failover` admin certificate; the server's store is Postgres, so its CA is `ca.crt` |
| `local-smoke` | no | it exercises only `zcube local`, which is the insecure listener's purpose |
| `demo-b7` | unchanged | it already runs both listeners and tests the insecure one |
| `bench-watch` | no | an in-process `Server` with `insecure_listen`: it measures the watch fan-out of 50 held polls, and a TLS handshake per poll would measure TLS instead |
| `server_test`, `cli_test`, `agent_remote_test` | no | in-process unit tests of the handlers, the CLI and the agent's client; `api_tls_test` and `tls_conn_test` test the transport |
| `swarm-smoke` | **no: gap** | converted in slice 7; see below |
| `demo-c2` | **no: gap** | converted in slice 7, for the same reason as `swarm-smoke` |

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

That is next to slice 5's agent-client work. The supervisor agreed (2026-11-14) that it becomes
**B7 slice 7**, done by a fresh session after slice 5 lands, before 0.5.1 ships (B7 makes TLS
the default, so 0.5.1 must not ship with C2's peer fetch silently broken). In that slice,
`swarm-smoke` and `demo-c2` move to TLS. `swarm-smoke` stays on `--insecure-listen` until then. Converting it is the pattern of
`agent-smoke`: the `pki` and `credentials` fields, `tls_ready` and `agent_tls`.

## CI

The harnesses run in the CI jobs they already had. Part 1's browser test, and whether CI runs
it, are left to the session that builds part 1.
