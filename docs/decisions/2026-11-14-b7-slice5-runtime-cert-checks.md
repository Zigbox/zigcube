# Certificate checks during a run (B7 slice 5)

*Decided 2026-11-14. The owner approved slice 5 for the `b7` release; the supervisor set its
scope. The choices below are the slice 5 implementer's.*

Before slice 5, a certificate was checked only when it was first used. The agent checked
`node.crt` when it started. The server read `revoked` when it started, and it checked a peer's
certificate only at the TLS handshake. So a keep-alive connection was never checked again, and
a name added to `revoked` took effect only after a restart. Slice 5 closes both gaps.

## The owner's approval

- The `b7` release carries slice 5. It adds no code and changes no bound.
- The server watches `revoked` for changes. It does not reload on SIGHUP.

## The choices

1. **Codes.** Slice 5 registers no new code. The server refuses a request with the same codes
   the handshake uses:
   - `ZC-E0811` when the peer's certificate has expired (`now >= not_after + 60 s`);
   - `ZC-E0819` when the peer's name is now in `revoked`.

   The agent reports its own expired `node.crt`, with no usable `--cert`, as `ZC-E0811`.
2. **Status and connection.**
   - A refused request gets `403` with the diagnostic as its body, and `Connection: close`.
   - The server does not read the request's body. It sends `close_notify` and closes the
     connection, as it does for any other refusal it does not read (`linger_refused`).
3. **When the server checks.** It checks each request on a TLS connection before handling it,
   the first request included. It uses the CA's wall clock (`peer_ca.Ca.wall`), which tests
   replace with a simulated one.
4. **Reloading `revoked`.**
   - The HTTP watchdog runs every `http_watchdog_ms` (500 ms). On each tick it compares the
     file's inode, size and modification time with what it last saw. When they differ, it reads
     the file and parses it into a scratch set.
   - **The file parses.** The new set replaces the old one, and the server logs one line,
     `zcube-server: revoked reloaded (N names)`.
   - **The file does not parse, or cannot be read.** The old set stays and the server logs one
     line naming the problem. It does not log again until the file changes again.
   - **The file is absent.** The set becomes empty. This is what the server does at start, when
     an absent file means nothing is revoked. Deleting the file is how an operator un-revokes
     every name.
   - A server with no state directory (the memory store) has no file to watch.
5. **Locking.**
   - The core's node renewal (`POST .../credential`) reads the set under `api_mutex`. The TLS
     checks (`caller` and the check before each request) read it under the TLS setup's mutex.
   - A reload takes both locks to swap the set in. It takes `api_mutex` with `tryLock`, so a
     long store write never stalls the watchdog. When the lock is busy, the reload is left
     pending and tried again on the next tick.
   - Issuance therefore uses the reloaded set from the tick that applies it.
   - `ca issue-*` is a separate process that reads the file when it starts, so it always sees
     the current file.
6. **The agent.**
   - **Before each new API connection,** the agent checks the window of the certificate it
     presents, using the same rule as the handshake: valid from `not_before - 60 s` to
     `not_after + 60 s`.
   - **Near expiry.** Once 3/4 of the certificate's life has passed without a successful
     renewal, the agent writes one stderr line naming the expiry and the last renewal error
     (or "none"). It writes the line again only after a renewal resets it.
   - **Expired, or not yet valid.**
     - If `--cert`/`--key` were given and that certificate is valid for this node, the agent
       switches to it and writes one note, as it does at start. It reads those files when it
       needs them, not at start, so a certificate written there later is picked up.
     - Otherwise the step fails with `ZC-E0811`. The message names the expiry, the last
       renewal error and why `--cert` could not be used. The fix is
       `zcube-server ca issue-node NAME --replace`.
   - **Pacing.** The failure goes through the agent's existing retry pacing. Each failed step
     renders one diagnostic, as a failed connection does.
   - **What counts as the last renewal error.** It is the cause of the agent's latest failed
     credential step: the peer join or renewal that issues `node.crt`. A successful renewal
     clears it.
7. **Teeth.** Each check has a test-only switch that skips it (`fault_skip_*`). Each switch
   has a teeth test that turns the switch on and asserts that the matching test then fails.

## Where

- `src/server_tls.zig`: the per-request check, and the lock around `caller`.
- `src/tls_server.zig`: the peer's `not_after` and `not_before`.
- `src/server_http.zig`: the check before each request.
- `src/server_revoked.zig`: the watch.
- `src/server.zig`: its wiring.
- `src/api_tls_client.zig`: the agent's check.
- `src/agent_http.zig`: where the agent calls the check, before each connection.
- `src/agent_run.zig`: where the agent records the last renewal error.
- `docs/mtls.md` and `docs/agent.md`.
