# C3: the owner's answers to the brief's questions

*Decided 2026-11-05, by the owner.*

Every question in `docs/briefs/c3.md`, "Questions for the owner" (1 to 11), is answered as
recommended there:

1. `Runtime.probe_begin` and `probe_poll` may be added; nothing else in `Runtime` changes.
2. In C3, "zero errors" means ready replicas never fall below the minimum at any store revision.
   Real traffic is measured in C4 (Mesh), and the README says so.
3. The rollout controller rolls back through the API's rollback handler, as a CAS on the
   service's revision, marked `applied_by "rollout-controller"`.
4. Every service gets the default rollout (rolling, `max_surge 1`, `max_unavailable 0`,
   `min_ready_ms 5000`, `ready_timeout_ms 120000`, `progress_deadline_ms 600000`,
   `grace_ms 10000`, `on_failure rollback`), including services with no health check. C0 to C2
   services change behaviour; slice 7 re-runs their demos and reports what it changed.
5. Each service keeps 16 generations of history. Rolling back to a compacted generation is
   ZC-E0128.
6. C3 has command health checks only.
7. Users address versions by generation. The demo's v1, v2 and v3 are image tags.
8. A rollout's cause outlives decision compaction in `/history` (`reason`, `restores`) and in
   the last rollout record.
9. Zigbox is asked to export its package writer (ZB-1). If that is not in the pin when slices 5
   to 12 are done, deb and rpm packages move to the next release.
10. `demo-c3` is the rollout demo only. Packages and the macOS build are needed for the C3 tag,
    but either may move to the next release without holding back the rollout.
11. Upgrading a cluster's agents with mixed versions stays parked.

Where: `docs/briefs/c3.md`.
