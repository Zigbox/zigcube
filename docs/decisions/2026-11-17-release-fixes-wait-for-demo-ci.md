# A release-branch fix reports only after its affected CI demos are green

*Decided 2026-11-17, by the supervisor, from the 0.5.2 retro.*

On #272, four fix passes each ended `check: PASS` and each broke a KVM demo job that `check`
cannot run (demo-b3, demo-b4). A fix session on a `claude/release-*` branch therefore does not
report until the CI demo jobs its change can affect (`.github/ci-changes.sh`; a release PR runs
them all) have run green on the head it reports, and the report quotes that run. `check` is
still required; it is not sufficient on a release branch.

Where: `docs/retros/0.5.2.md`.
