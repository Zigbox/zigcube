# demo-c1 (sqlite) failed once in CI: a server-wide stall of about 13 s

Run 42355098100, job 128351380038, commit c16cacf (PR #150, merged into 33357f0). It passed on
the next commit and did not reproduce locally (7 runs, 3 under CPU load; plus 1 more at the
head of main for this note). **Root cause not found; no defect proved.** This note says what the
log does and does not show.

## What the log shows

- Step 3 began at 08:23:26.02 (runner clock) and `kill -9` of node3 finished at 26.52. The demo
  then waited 13 134 ms for node3 to read lost: 13 638 ms after the power-off, where the lease of
  8000 ms allows 4084..10250 ms.
- Within the same window node1 (lease 2) and node2 (lease 1) both fenced (`ZC-W0501`, "lease
  could not be kept") and node2 logged `ZC-E0503` "did not answer in time". Two agents on two
  routes (node1 through the fault proxy, node2 direct) failing together, and the controllers'
  `mark_lost` coming late, point at the one thing they share: **the server did not answer for
  roughly the ttl (8 s) or more.** Not at node3's agent (dead), not at the proxy (node2 is direct).
- The build step before the demo took 2m11s on that runner, with `translate-c` at 46 s: it was
  a slow runner, but that is evidence about the build, not about the 13 s.
- The log has **no timestamp inside the demo's output**, so it cannot tell whether the stall was
  the server process only (a blocked fsync, a lock) or the whole machine (the demo's own sleeps
  late too). "Runner stall" is therefore plausible, not proved.

## Reproduction

- `SIGSTOP` of `zcube-server` for 9 s right after node3's agent dies reproduces the signature:
  both surviving agents fence, `lost` is read late (here 8.6 s, since the stall ends at 9 s), and
  the step fails. So a stall of the server of that length is sufficient. Nothing else was needed.
- Not reproduced without an injected stall: 1 baseline run at this commit passed.

## Suspects, checked by reading the code

- **SQLite write serialisation.** `SqliteStore` has one mutex around every call, and the server
  opens in `Sync.full`: each commit fsyncs. A single fsync that blocks for seconds on a shared CI
  disk would hold the mutex and stop every agent call and the controllers at once, which is the
  observed signature. Nothing in the code bounds an fsync. This is the most likely server-side
  mechanism but is unproven (no timing in the log).
- **Watches.** A held watch polls under the same mutex every `store_watch_poll_ms` (10 ms); with
  3 agents that is light. `http_holds_max` (50) is far from 3 agents' holds; a refusal would be
  `ZC-E0108`, not E0503.
- **Paged job-observed (#148).** No job in step 3; it adds no reads there.
- **Agent deadlines (#150).** `calls_deadline_ms` ends a call at the fence or a run's wake, but
  never sooner than `call_inflight_min_ms` (1 s). It explains why E0503 is how the stall surfaced,
  not why the server was silent. No run has a deadline in this demo.
- **WAL checkpoint.** Auto-checkpoint of a small WAL runs on commit, in the mutex; it does fsync,
  so it is the same suspect as above, not a separate one.

## What the demo records now (this change)

`Host.wait_for` prints `STALL: a poll took N ms` or `STALL: a sleep of poll_ms took N ms` for any
poll or sleep over 2 s, with the offset into the wait and the demo's clock. Under the 9 s
`SIGSTOP` above it prints `STALL: a poll took 8538 ms`. A recurrence then reads:

- slow poll, sleeps on time: the server (or `zcube`) did not answer; look at its fsync.
- sleep overshoots too: the demo process or the machine did not run; a runner stall.

## Proposed, not done (needs a decision: it adds a server log line / a limit)

- A timestamp on every line of the server's and agents' stderr that the demo echoes on failure.
- The server logging any store call that holds the SQLite mutex for more than 1 s (cause, how
  long, which call). That would turn "unproven" into "proved" in one recurrence.
