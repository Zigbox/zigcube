# B7 slice 4 handoff: stock clients and demo-b7

*Decided 2026-11-13, by the slice.*

## What landed

- **Server rows for `mtls-interop`.** These live in `src/mtls_interop_server.zig` and `ops/mtls-interop/InteropClient.java`.
  - `openssl s_client` and a JDK 21 `SSLSocket` each call a real `zcube-server --listen` on SQLite.
  - With a `jobs` client certificate from `ca issue-client`, each is accepted: `GET /v1/jobs` is 200, `GET /v1/status` is 403, and the server logs no refusal.
  - Each is refused in three cases:

    | Certificate presented | Alert the client sees | Server log |
    | --- | --- | --- |
    | none | `certificate_required` | ZC-E0814 |
    | expired, signed by the server's own CA | `certificate_expired` | ZC-E0811 |
    | from another CA | `unknown_ca` | ZC-E0810 |

  - That makes 8 rows; `mtls-interop` now has 32 cases in all.
- **`demo-b7`** (`src/demo_b7.zig`, `src/demo_b7_steps.zig`, `docs/demos/b7.md`).
  - It runs on SQLite with no KVM, and is wired into CI's `demos (sqlite)` job.
  - `ci-changes.sh` has a new `demo_b7` column. The shared demo state files want it too, because `demo-b7` imports `demo_b1_state.zig` and `demo_c1_state.zig`.
  - `demo_host.Config` has a new `tls_listen` field. When it is set, the host's server also gets `--listen`.
- **A server fix in `src/server_http.zig`: `linger_refused`.**
  - The problem: in TLS 1.3 the server judges the client certificate before it reads the client's Finished. When the server refused a handshake, it closed at once. The kernel then answered the client's Finished with a reset, and the reset destroyed the alert. So the JDK sometimes saw "Broken pipe" instead of the alert.
  - The fix: both refusal paths in `serve_tls` now shut down the sending side and drain at most `http_linger_bytes_max` bytes. This is the same pattern as `linger`, under the same watchdog (the slot is `.waiting`).
  - No bound, limit or code changed.

## Traps

- **The `jobs` client cannot run `zcube get nodes`.** It is refused, so the demo reads node state as `/nodes/<name>` through `GET /v1/list` on the insecure listener. `demo_c1_state.node_rows` goes through the CLI and would fail.
- **The agent's files are in different formats.**
  - `state/node.crt` is PEM.
  - `state/peer.key` is a hex seed, not PEM. Read it with `peer_files.read_seed`.
  - To act as node1, the demo builds `Credentials` from `load_ca` plus `present`.
- **A request with no certificate.** `tls_conn.Conn.open` succeeds with `client_auth = .none`, and the refusal arrives on the first read. The client's own code is then ZC-E0814.
- **Don't add a client-side "wait for the alert" in `InteropClient.java`.** It does not fix the reset described above. The server-side linger does.

## Not done or left to others

- **README and site status rows:** left to the supervisor.
- **Mechanical parts left for Haiku in the brief:** none were needed. No new codes, so the errors site is unchanged.
- **`demo-b7` is not a passed demo** until CI's `demos (sqlite)` job runs it green. B7 is done only then.

## Next

B7 is complete after review. The brief's done-means applies: `demo-b7` must be green in CI.

Where: `docs/demos/b7.md`, `docs/mtls.md` (interop), AGENTS.md (commands).
