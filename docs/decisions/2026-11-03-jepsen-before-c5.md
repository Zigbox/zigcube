# An external Jepsen analysis is a C5 prerequisite, run out of tree

*Decided 2026-11-03, by the owner.*

Before C5 (self-hosting on EC2, the first release that claims its consistency to people who rely on it), Zigcube gets a real Jepsen battery. Not before: C2 to C4 are gated by the in-tree checks.

- **Out of tree.** Jepsen is Clojure and drives nodes over SSH, which the no-third-party-dependencies rule does not allow in this repo. It lives in a separate harness repo, or, better, is an independent external analysis.
- **What it runs against:** a real 3 to 5 node deployment (server, agents, Postgres primary and standby) with network partitions between hosts, clock skew, process pauses (SIGSTOP) and Postgres failover.
- **Why, given what exists:** `test-store-faults` (fault proxy plus the history checker in `src/testing/history.zig`), the two failover runs (`sync` loses nothing, `async` halts with ZC-E0215), sim-c1's invariants and the always-on fleet are Jepsen-style but single-host, and written by the people who wrote the code. Real multi-host faults and an outside reader are what they lack.
- **Release:** the C5 release notes cite the report. It sits with the other C5 prerequisite, open-sourcing the server-side TLS/mTLS (the O3 notes in `docs/supervisor-handoff.md`). The TLA+ model of fencing stays a C7 prerequisite.

Where: `docs/supervisor-handoff.md` (C5 prerequisites); the C5 brief when it is written.
