# A test-only late fence kill for the Jepsen lease test's negative control

*Decided 2026-11-14, by the supervisor under the delegation of
`2026-11-13-supervisor-decides-under-delegation.md`.*

## Decision

`c1_teeth.fence_stop_teeth`, declared only by the new root `src/zcube_agent_fence_teeth.zig`,
makes the agent kill what a fence has not stopped 8,000 ms after the fence instead of
`fence_stop_ms` (2,000). `fencing.kill_at_ms` reads it; nothing else does. `zig build` installs
the result as `zcube-agent-fence-teeth`, which is never released. The server, every other
program and every test have another root, so for them the switch is false and the default
runtime is unchanged; `zcube_agent.zig` asserts at compile time that its own root leaves it off.
It is not in `c1_teeth.any`, since the agent root it builds on asserts `!any`.

## Why

The Jepsen lease test (zigcube-jepsen, slice 2) checks I1b with a measured overlap against the
bound `fence_stop + skew + kill latency` = 1,900 ms. Its negative control so far is a
SIGSTOP-wedged agent, which is an environment fault, not a protocol one. A tooth in the
protocol's own code shows the checker catches a wrong agent too.

A lower agent-only `fence_margin` was considered and rejected: it moves the fence later by
about the cut, giving an overlap of about `200 - m` ms, which never passes 1,900. A later kill
leaves a replica running past the bound: the Jepsen partition run measured a 3,335 ms overlap,
with 6 handovers past 1,900 ms.

Where: `src/c1_teeth.zig`, `src/fencing.zig`, `src/zcube_agent_fence_teeth.zig`, `build.zig`.
