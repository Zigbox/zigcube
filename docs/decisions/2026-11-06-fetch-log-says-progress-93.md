# fetch.log says progress and the registry pull (issue #93)

Date: 2026-11-06. Status: decided (no new diagnostic code; owner confirmation not needed).

## Context

The zigbox-smoke `peers_fetch` flake (#93, CI run 42158708052): "timed out after 240s waiting for
pyone to run on peerb". Re-review 5795673433 of #109 asked why peerb's discovery found no usable
holder, and why the supervisor's registry pull after ZC-W0603 did not get pyone running.

## What the log shows

Read in full, the log answers neither question as asked. The ZC-W0603 and O5 lines belonged to
node A's containers, not peerb's. Peerb's `fetch.log` held only the "left out" line, and the fetch
process was still running at the end: discovery had succeeded (`.peers`, A seen holding the tree)
and the fetch then went silent for 240 s. The supervisor's registry pull never started, so there is
no pull outcome to explain. Every transport wait is bounded in the code (10 s request, 20 s busy
wait, 3 timeouts, 30 min total), so static reading does not say which step stalled. The cause is
not known.

## Decision

Make the next occurrence say where it stopped, without a new code:

- the fetch writes a progress line to `fetch.log` (chunks asked, bytes received) at most every
  `fetch_progress_ms` while it asks peers for chunks;
- the supervisor writes a line when its registry pull starts and one with the outcome, and a line
  when no fetch was needed;
- `drop_pull` removes the file first and then counts and notes the drop, so a failing remove no
  longer counts the same record at every step (tests in `api_test.zig`).

If the next flake shows a progress line that stops, the stall is in the peer transport at that
chunk; if there is none, it is before the first chunk (the bundle). The issue stays open until then.
