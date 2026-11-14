# C3: a scale down while a rollout is paused or failed, counted as the replica controller counts it

*Decided 2026-11-14 by the supervisor (ruling on Review B, MUST 1, of C3 slice 7: take the
controller's rule unless it breaks R4's intent); recorded by the slice 7 fix session.*

**The disagreement.** Seeds 202 (`sim_cluster 202 150 0 --c3 --heal-at=125`) and 207 (`--heal-at=127`)
failed R4 ("a paused rollout retired a replica"). The user scaled a service down while its
rollout was paused. The replica controller's keep is live + held + stale, and a halted rollout
wants `replicas + max_surge`; it removes the excess, cheapest first (not running, then the
highest number). The checker counted only the replicas it judged running (not stopped, not on a
node whose state is not `ready`), so it saw no excess and called the removals retirements. In 207
`alpha` wanted 2 with 4 records, two on not-ready nodes; the controller removed `alpha-4` (gen 2,
not yet observed). In 202 `beta` wanted 1; it removed `beta-22` (a held new replica) and `beta-21`
(an old one never placed).

**Decision: the controller's rule stands; `sim_c3.scaled_down` counts as it does.** A replica
counts toward the excess unless its report says stopped and it is not held by the user's fault
(`replica_controller.user_fault`); a replica on a node not yet judged lost counts. R4's intent, "a
paused rollout never retires a replica that was serving the old or new generation", holds: the
removals are the user's scale down, never more than keep − (`replicas` + `max_surge`), and the
victims are those not running first. The checker is therefore a little weaker, in line with
docs/core.md ("never stronger than the brief"). Both seeds are in `c1_regressions` (`build.zig`).

**Also decided in the same fix (review items without a ruling of their own).**

- *R1 is judged on running; the budget is computed on ready* (Review A SHOULD). A replica
  created since the budget (the `/replica-numbers` counter moved past `budget_next`: a
  replacement, or a start) is not ready, so a retirement of a running replica waits for the
  rollout controller to count again (`replica_controller.started_since`); a retirement costs one
  pass more after a creation. Review A's scenario (a replacement makes `n3` running, then a
  retirement leaves 2 ready of 3) can no longer happen on a stale budget. The sim's R1 still
  checks running, not ready: the controller's floor (`expect_floor`) is on running.
- *`from` with no earlier rollout counts only generations that were ready* (Review B SHOULD 4):
  an old replica counts when observed running for `min_ready_ms`, else `from` is 0 and a failure
  owes no rollback. A server restarted less than `min_ready_ms` before an apply sees no ready old
  replica (its readiness clocks restart) and so starts that rollout from 0: safe (no rollback to
  a generation it cannot vouch for), at the cost of no automatic rollback for that rollout.
- *`count_deaths` is a lower bound* (Review B SHOULD 7): a new replica that dies, is replaced and
  is deleted before any pass saw its report is never counted. The restart bound can therefore be
  passed later than the brief's count says, never sooner.
- *`replace` no longer removes one dead replica at a time during a rollout* (Review B SHOULD 8):
  the old `removals_max = 1 when stale > 0` had no stated reason. A dead replica serves nothing,
  so removing two costs no availability; creations stay bounded by `room` (R2) and by the
  removals while stale replicas remain.
- *R2 is judged in every phase* (Review B SHOULD 9), paused and failed too: a halted rollout keeps
  its surge and a replacement is bounded by `room`.

Where: `src/sim_c3.zig` (`scaled_down`, `surge_problem`), `src/replica_controller.zig`
(`choose_retired`, `started_since`, `replace`), `src/rollout_controller.zig` (`View`),
`build.zig` (`c1_regressions`), `src/rollout_controller_test.zig`.
