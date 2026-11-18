# Jepsen runs on GCP, applied and torn down by CI

Date: 2026-11-18. Decided by the owner (2026-11-17), recorded by the supervisor. It follows
`2026-11-15-jepsen-on-google-cloud.md` and records the setup as built and its first run.

## Decision

The Jepsen battery (`Zigbox/zigcube-jepsen`, the C5 prerequisite in
`2026-11-03-jepsen-before-c5.md`) runs on throwaway GCP VMs that CI creates, uses and destroys.

- GCP project `zigcube-jepsen`, OpenTofu in `zigcube-jepsen/tofu/`.
- `gcp.yml` builds Zigcube at a chosen ref in a job with no GCP access, then a second job
  authenticates through Workload Identity Federation (pool `github`, provider `zigcube-jepsen`; no
  key files), applies, ships the harness, runs the tests on a control VM over IAP, collects the
  results, and `tofu destroy` runs whatever happened, then checks that nothing of the run is left.
  `gcp-sweeper.yml` deletes anything a lost run leaves behind.
- The provider's condition admits only that repository (by id and owner id), `refs/heads/main`,
  and those two workflows.
- Size: 5 nodes and 1 control VM, all `e2-standard-2`, in `us-central1-a`: 12 vCPU, the project's
  global `CPUS_ALL_REGIONS` quota, which will not be raised
  (zigcube-jepsen `docs/decisions/2026-11-17-gcp-12-vcpu.md`). There is no headroom: a second
  run at the same time fails at apply.

## First run

Run 44197582669 (Zigcube `7fe600b`; tests api-fenced, pg-fenced, lease-valid, lease-wedged;
120 s each): about 25 minutes end to end (build 8 min, apply and SSH 3 min, tests 10 min,
destroy 2 min), and nothing was left.

- `pg-fenced` passed: 4 Postgres failovers and 4 rejoins under partitions, history valid, write
  outage per failover 5.2 to 5.4 s.
- The other three never started: the harness spoke plain HTTP to `zcube-server --listen`, which
  serves mTLS since B7. The harness is being fixed to present client certificates; the server is
  not weakened.

## Consequences

- A Jepsen result quoted in a release PR names the `gcp.yml` run and the Zigcube ref.
- A harness that talks to the server follows Zigcube's TLS rules (`docs/mtls.md`).
