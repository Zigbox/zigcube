# B4 slice 2: partial, handed off at the context ceiling

*Decided 2026-11-13, by the slice (implementer session, stopped at the context ceiling).*

B4 slice 2 is not finished. The first implementer stopped at the context ceiling, and a fresh
session continues on `claude/b4-slice2` (based on `claude/b4-slice1`, PR #233).
`zig build check` has **not** been run on this branch. agent-smoke has not been run either.

## Done (committed, unit tests pass)

- **ZC-E0706** is registered: `codes.zig`, the golden files and the errors site.
  - `api.status_for` maps it to **409**, not to the 503 its `environment` blame would get by
    default. The run lost its claim, and a retry will not fix that. Flag this to the supervisor.
- **Config.**
  - `JobRelay` gains `server_name`, `server_anchor` (64 hex) and `plain`.
  - `server_config` reads `relays.<name>.server_name` and `server_ca` (a PEM Ed25519 anchor,
    `pem_anchor`). A bad entry is ZC-E0106.
  - `plain` is accepted only in Debug builds (`relay_plain_allowed`).
  - There is a new server setting, **`.cluster`** (the SPIFFE trust domain). The endpoint answers
    404 until it is set. This is a new user-visible setting and needs the supervisor's approval;
    flag it in the report.
- **`POST /v1/agent/runs/<name>/certificate`** (`agent_api.run_certificate`).
  - The body is `{public_key, epoch, image_digest}` (hex).
  - The reply is `{certificate (hex DER), not_before_ms, not_after_ms}`.
  - The subject comes from the job, status, claim and assigned keys, read at one revision. The
    epoch is the mod_revision of the `/assigned` kv.
  - `job_cert.decide` makes the decision. Signing is `peer_ca.Ca.issue_job_certificate`.
  - Test: `api_test` "a relayed run's certificate: ...".
- **TLS client.**
  - `tls_client.ServerProfile` (`cluster` or `foreign`) and `tls_conn.Options.server_profile`.
    `foreign` verifies with `x509.verify_foreign_server`.
  - `tls_testpeer.ClientAuth.name` (the expected SPIFFE URI). `Peer.client_leaf()` returns the
    client's certificate for the test upstream to decode.
  - `tls_testpeer` uses global buffers, so run one handshake at a time.

## Next, in order

1. **The relay over TLS** (`src/relay.zig`).
   - `connect_upstream` opens a `tls_conn.Conn` with `client_auth = .required` and
     `server_profile = .foreign`, against the entry's anchor and name.
   - The copy loop gets a TLS `Sys`. It must not wait in `poll` while `Conn.pending()` holds
     bytes. The byte and idle bounds count plaintext.
   - `plain` keeps B3's path.
   - `stop` shuts down every slot's fds. `relay_cancel_ms_max = 2 * relay_poll_ms`, with a
     comptime assert and a timing test.
   - Test upstream: a thread that accepts on 127.0.0.1 and runs a `tls_testpeer.Peer`. Copy the
     handshake helpers from `tls_conn_test.zig`. It uses its own CA for its server leaf and pins
     the cluster CA for the client. It checks the job, digest, epoch and labels with
     `x509_identity.decode` on `client_leaf()`, and it must refuse each bad case: another job, an
     expired certificate, another CA, and no certificate.
   - Fuzz the TLS copy loop with short reads and writes.
2. **Key and fetch.**
   - The fake supervisor makes the Ed25519 pair (`secure_random.zig`) and keeps it only in
     memory.
   - It writes a public request, `relay.pub` (job, epoch, digest and public key, taken from the
     `zcube.job`, `zcube.created` and `zcube.image` labels), into the container directory.
   - An agent_run Shell step polls for requests that have no answer yet, POSTs them (follow
     `agent_peer.join` for the transport call) and writes `relay.crt`. On ZC-E0706 it writes the
     refusal line to `relay.log` and a refused marker.
   - The relay waits for `relay.crt` before it dials. A refused run's relay stays closed.
3. **Spec.** A relayed run's spec gets loopback-only networking. The adapter refuses anything
   more, with a test (the fence comparison, row 2).
4. **Fail-closed tests.**
   - The relay fails to open: the command never runs (ZC-E0702).
   - The relay stops mid-run: the supervisor kills the command and writes the cause to
     `relay.log`.
   - Each needs a test-only fault in `<state-dir>/faults/` and a tooth. Ask before adding a code
     for "relay stopped".
5. **Smoke and docs.**
   - agent-smoke's relayed job goes through TLS.
   - `demo_b3`'s config needs `plain` or a test upstream. `plain` works only in Debug, so check
     the mode `demo-b3` builds in.
   - Docs: `docs/api.md` (the endpoint, 409), `keys.md`, `agent.md`, and `mtls.md`'s threat list
     (issuance is unauthenticated until B7, O4).

## Traps

- `x509.parse_profile` takes `&detail`. `public_key` is a span: use `.of(bytes)`.
- `"00" ** 32` does not parse in a test literal; use `@splat('0')`.
- Keep slice 3 (`claude/b4-slice3`) in mind: nothing above should change `job_cert.zig`.

Where: `docs/briefs/b4.md`, this branch's commits.
