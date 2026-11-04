# C3 input: a harder simulation fleet

Owner, 2026-11-04: what we can think of to get more value out of the simulation fleet goes into
C3. This is a list to fold into C3's brief when it is written, not a brief.

**Already in C2, because C2's ship gate needs it** (branch `claude/sim-fleet-2`): the fleet runs
`sim-swarm` and the `--c1` checks alongside plain `sim-cluster`, so the release rule's 24 hours
covers every simulator C2 gates on.

## For C3

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
5. **PR heads, not only main.** The fleet also runs on the head of each open PR for a few hours, so
   a failure is found before merge, and comments on the PR.
6. **Mixed versions.** Agents at the previous release with a server at the new one, and the other
   way round, for rollouts: C3's own subject.
7. **Coverage feedback.** Record which checks, faults and code paths each seed reached; bias new
   seeds toward the least reached (cheap: counters in the simulator report, not a coverage tool).
8. **Long soak.** One machine runs a single seed for hours with a growing history, for leaks,
   counter overflow and slow drift that short runs never see.
9. **Shrinking and replay as artefacts.** Each filed issue carries the shrunk replay command and
   the trace, so a fix session starts from the smallest failing run.
10. **Rollout invariants** (C3): no more than the surge budget unavailable during a rollout, no
    replica running a version that was never applied, a paused rollout stays paused.

## Machines

After 1 to 3, if the fleet's runs are no longer finding new states per hour, add machines. A Fly
fleet (or similar) works for the simulators, which are pure CPU. It cannot run the VM demos, which
need KVM.
