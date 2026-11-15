# The B7 soak on ad4c6ca covers Zigcube 0.5.2

*Decided 2026-11-15, by the owner (relayed by the supervisor).*

The fleet's 24-hour soak runs on `ad4c6ca` (main after the B4–B7 bundle, #258), pinned through the
branch `release-test/b7-soak` (`SIM_FLEET_BRANCH`), so `main` can move during it. The changes that
come after it for the 0.5.2 release, namely the version bump to 0.5.2, the pin to Zigbox v0.5.2 and
B4 slice 4, need no second soak. Each needs only:

- `zig build check` passing on the release commit, and
- a full CI run (`full-ci`, or a `claude/release-*` pull request) green on it.

This is an exception for this release under AGENTS.md's "Sim-clean" rule, not a change to the
rule. The other release gates stand: no `sim-fleet` issue open against the soaked commit, and two
independent Opus reviews of the diff since the last release, the follow-ups included.

Where: `docs/releases/b4-b7.md`, `ops/sim-fleet/README.md`.
