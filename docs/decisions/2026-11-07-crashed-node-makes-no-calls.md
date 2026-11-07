# A crashed sim node makes no calls to the server (#167)

Date: 2026-11-07

## Decision

`Node.tapped_call` in `src/sim_cluster.zig` refuses every call with ZC-E0503 while the node's
agent is crashed (`sim.crashed` or `sim.files.crashed`), before it reaches the network. A
crash that deadline enforcement swallows therefore ends the step at its next server call
(heartbeat, `publish_store`, `load`), as a real crash would. No new code is registered:
ZC-E0503 is the code the agent already sees for a server it cannot reach.

## Which world a seed means

Seeds that crash an agent mid-step and then went on to call the server mean a different world
now: those calls no longer cross the simulated network, so they no longer spend its random
draws, link time or server state. Seeds that never reach this path are bit for bit unchanged.
Seed 57 at 100 operations (`--c1`) is one that reaches it (two refused calls). Replay lines
recorded before this change may not reproduce for such seeds; nothing is fixed to a recorded
report hash.

## Test

`a crashed node's step makes no call to the server (#167)` in `sim_cluster.zig`, with an
assert in `tapped_call` that nothing reaches the net from a crashed node. Without the gate,
seed 57 aborts on that assert.
