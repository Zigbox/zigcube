# C2 ships without the 24-hour fleet run; C3 starts by upgrading the fleet (owner, 2026-11-04)

C2 is released without the release rule's sim-clean gate: the simulation fleet does not run 24
hours on the shipping commit. C3 begins by changing the fleet (docs/briefs/c3-sim-fleet.md), which
makes results from today's fleet of little further value, so waiting on them would delay C2 for
little evidence.

Everything else in the rule still applies to C2: `demo-c2` green in CI, `zig build check` passing on
the shipping commit (which runs `sim-cluster`, `sim-c1`, `sim-swarm` and the teeth runs with fresh
seeds), two independent Opus reviews with every MUST fixed or accepted in writing, and a retro.

This is a one-time exception for C2. It supersedes the 24-hour part of
docs/decisions/2026-11-04-release-gates.md for C2 only. From C3 on, the full rule applies, run by
the upgraded fleet.

The fleet work already in flight (branch `claude/sim-fleet-2`, PR #71: `sim-swarm` and the `--c1`
checks in the fleet) is no longer a C2 gate. It lands as the first step of C3's fleet upgrade.
