# B2 ships without the `job_reuse` tooth (issue #195)

*Decided 2026-11-09, by the owner.*

The owner accepts the absence of RB-N8's `job_reuse` tooth for B2, as
`2026-11-09-b2-rbn8-teeth-evicted-built-reuse-not.md` asked: "job_reuse accepted, ship B2
without it".

- B2 is tagged without it. Nothing else in the ship gate changes.
- The stale-epoch rule stays covered by the unit tests of `agent_jobs.zig`. No simulation shows
  that a reused job name never meets a leftover container.
- Building it is B3 work. The seam is a store-side retention jump that does not tick every agent
  (a new seam in `Cluster`), then a measured hit count before a seed range is chosen. It is on the
  B3 follow-up issue.

Where: `docs/decisions/2026-11-09-b2-rbn8-teeth-evicted-built-reuse-not.md`, issue #195.
