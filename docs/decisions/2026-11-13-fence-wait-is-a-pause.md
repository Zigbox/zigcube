# A wait while fencing is a pause, not a watch

Date: 2026-11-13. Status: implementer's decision for #225; no bound or default changed.

## What happened

sim-cluster: "an agent took too many steps for the time it was up (a busy loop)", seeds 9739923
(114 operations) and 2764708423 (69), `--strong --profile=crash_heavy`, step `end`.

## Evidence

Logging every step of the busiest node (node1, 1105 steps, 609 of them in the same millisecond as
the one before): up to 52 steps in one millisecond, each with `acted=0`, `fence.active=true`, a
wake time 100 ms ahead (`fence_poll_ms`) and the node clock unchanged. Not the check's budget: an
agent in steady state steps about 69 times a minute, far under the 200 ceiling.

Cause: while fencing, `Agent.reconcile` returns `fence_step`, which makes no replica list.
`RemoteStore.watch_from` is 0 after a restart or a resync, and `watch_once` with `watch_from == 0`
returns "changed" without a call or any time passing ("the list will say where we are"). The loop
then stepped again at once, and did so until the fence ended (all containers stopped, or killed).
The real agent runs the same loop (`agent_run.zig`), so this is a product bug, not a simulator
artefact: a hot loop for the length of a fence.

## Decision

`Wakeup.watch` (default true) is false from `fence_step`; `Loop` then answers a wait with
`pause_ms` (at most one watch slice, cut at the fence by the shells) instead of `watch_ms`. The
ceiling stays 200 a minute; no limit, default or code was added. Regression: the two replay lines
in `c1_regressions` (both failed before) and a `Loop` unit test.
