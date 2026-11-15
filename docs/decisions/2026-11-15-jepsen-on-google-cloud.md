# The Jepsen battery runs on a throwaway Google Cloud cluster

*Decided 2026-11-14, by the owner; recorded 2026-11-15 by the supervisor.*

This adds where and how to `2026-11-03-jepsen-before-c5.md`, which still holds.

- **A cluster per run.** Each run creates a small cluster on Google Cloud, runs the battery, and destroys the cluster. There are 3 to 5 small VMs (server, agents, a Postgres primary and standby). A run takes a few hours, not 24: the 24-hour soak is the simulation fleet's rule, not Jepsen's.
- **Credentials.** GitHub Actions reaches Google Cloud through Workload Identity Federation. No service-account key file exists, and none goes through chat or an agent session.
- **Its own repository.** The harness (Clojure, SSH, cloud set-up) lives in a separate repository, not in this one, so this repository's no-third-party-dependencies rule stands.
- **Gate.** A release that needs Jepsen-clean (AGENTS.md, "Releases") cites a passing run on a Zigcube commit pinned to it. The C5 brief carries this when it is written.

Where: `docs/supervisor-handoff.md` (C5 prerequisites); the C5 brief.
