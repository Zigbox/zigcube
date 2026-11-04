# C3 input: a harder simulation fleet

Owner, 2026-11-04: what we can think of to get more value out of the simulation fleet goes into
C3. This is a list to fold into C3's brief when it is written, not a brief.

**First in C3** (owner, 2026-11-04, docs/decisions/2026-11-04-c2-ships-without-fleet-soak.md):
C2 ships without a 24-hour fleet run, and C3 starts with the fleet. The work in flight on branch
`claude/sim-fleet-2` (PR #71: the fleet runs `sim-swarm` and the `--c1` checks alongside plain
`sim-cluster`) lands first; the items below follow.

## For C3

Owner, 2026-11-04: each item below is a slice of C3. Two more ideas are parked, below.

Variety before machines: each item makes a run explore states the current one never reaches.

1. **Fault profiles (swarm testing).** Each run draws a profile that switches whole fault classes
   on or off (partitions only, clock skew only, crash-heavy, a slow store, lying peers only) instead
   of always using the same mix. Rare interleavings show up when most faults are off.
2. **Varied shapes.** Draw `ops` (40 to 5,000), `nodes` (1 to 16), replica counts and lease TTLs
   per run, with long runs at a fixed share of the time. Today every run is 3 nodes and 100 ops.
3. **A teeth canary.** About 1 run in 50 runs a build with a test-only fault switched on and must
   fail. If a canary passes, the fleet files an issue: the fleet itself has stopped detecting.
4. **`test-store-faults` daily** on Postgres and SQLite, including the failover runs, with the
   fleet filing failures like simulator failures.
5. **Coverage feedback.** Record which checks, faults and code paths each seed reached; bias new
   seeds toward the least reached (cheap: counters in the simulator report, not a coverage tool).
6. **Long soak.** One machine runs a single seed for hours with a growing history, for leaks,
   counter overflow and slow drift that short runs never see.
7. **Shrinking and replay as artefacts.** Each filed issue carries the shrunk replay command and
   the trace, so a fix session starts from the smallest failing run.
8. **Rollout invariants:** no more than the surge budget unavailable during a rollout, no replica
   running a version that was never applied, a paused rollout stays paused.

## Parked (owner, 2026-11-04: not in C3)

- **PR heads, not only main.** The fleet also runs on the head of each open PR for a few hours, so
  a failure is found before merge, and comments on the PR.
- **Mixed versions.** Agents at the previous release with a server at the new one, and the other
  way round, for rollouts.

## Machines

After 1 to 3, if the fleet's runs are no longer finding new states per hour, add machines. A Fly
fleet (or similar) works for the simulators, which are pure CPU. It cannot run the VM demos, which
need KVM.
