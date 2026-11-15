# B7 slice 5 review fixes: the revoked reload, the guard's own E0811, one reload bound

*Decided 2026-11-14 by the supervisor (R1 to R3), on the B7 slice 5 review; made by the slice 5
fix session. Adds to `2026-11-14-b7-slice5-runtime-cert-checks.md`, which it corrects where
noted and otherwise leaves standing.*

## R1. An absent `revoked` file, or a vanished state directory

The set stays empty, as at start (an absent file means nothing is revoked). The server now logs a
line of its own, once per transition from present to absent:
`zcube-server: the revoked file is gone: every name is un-revoked`. A state directory that has
vanished looks the same as an absent file. Tests: "a revoked file that is gone empties the set
with a line of its own, once (R1)" and the real-file test with the state directory deleted
(`src/server_revoked.zig`).

## R2. A reload is not starved by a busy API

`apply` first tries `api_mutex` without waiting, as before. After `busy_ticks_max` (4) failed
tries it takes the mutex blocking, on the watchdog thread; the bound is asserted. Four is small
enough that the bound below stays within 5 s, and large enough that a single long request does
not stall the watchdog's other duties. The test holds `api_mutex` across the tries, then holds
the TLS lock while the blocking tick waits for it, and checks the set is unchanged until the TLS
lock is released: a reload that swapped without the TLS lock (mutant M4) fails it.

## R3. Change detection

- The look compares inode, size, mtime **and ctime**, so a write that restores the mtime is still
  seen.
- A look whose mtime is within 2 s of the CA's wall clock (`racy_ns`) is unsettled: the next tick
  looks again (git's racy-index rule; a coarse-mtime file system could otherwise hide a second
  write in the same timestamp).
- After the load the file is looked at again; the read is discarded unless that look equals the
  one that triggered it, and the next tick retries.
- `docs/mtls.md` tells operators to write the file elsewhere and rename it over `revoked`.

## One reload bound: within 5 seconds

`apply_ms_max` = 2,000 (settle) + (1 + `busy_ticks_max`) × `http_watchdog_ms` = 4,500 ms, asserted
at most 5,000, plus the write under way when the blocking tick starts. Every text now says "within
5 seconds": the fix in `ZC-E0807`, `agent_peer.zig`, `docs/mtls.md`. The earlier decision's
"within two ticks" is superseded. No constant changed and no user-visible bound or limit was
added: the sentence only names the bound the code had.

## S1. The guard's own E0811 does not overwrite the renewal error

`Guard.raised` counts the guard's own refusals. `Peer.step_guarded` notes it before the step and
calls `renewal_failed` only if the step failed for another reason (the server's refusal), so the
next E0811 still names the last renewal error (e.g. `ZC-E0807`).

## Corrections and notes

- The earlier decision says a refused request is closed "as it does for any other refusal it does
  not read (`linger_refused`)". The function is `linger`; `linger_refused` is the refused
  handshake's.
- A request in flight when a name is revoked (a held long poll included) completes; the refusal
  comes with the connection's next request. A recheck when `wait_for_change` wakes
  (`src/server_http.zig`) was considered and left as a follow-up: it would give the revoked
  agent one fewer answer, at the cost of a check in the hold path, and nothing depends on it.
- `ca issue-*` runs as a separate process that reads the file when it starts (`docs/mtls.md`).
- An agent started without `--cert`/`--key` must be restarted with them (`docs/agent.md`).

Where: `src/server_revoked.zig`, `src/api_tls_guard.zig`, `src/agent_peer.zig`, `docs/mtls.md`,
`docs/agent.md`.
