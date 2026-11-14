# C3 slice 7: the rollout controller and the replica controller's budget

*Decided 2026-11-14, by the slice (C3 slice 7, `src/rollout_controller.zig`,
`src/replica_controller.zig`, `src/sim_c3.zig`), for the supervisor's review.*

Choices the brief left open, or where this slice differs from it or from slice 6:

1. **Readiness is observed `running`.** Slices 9 and 10 (probes, health) are not built. A new
   replica is ready once the controller has seen it `running` for `min_ready_ms`
   (`rollout_controller.Track.running_since_ms`). Slice 10 plugs in at `Track.update` and at the
   `running` flag the controller computes per replica: "running" becomes "running and healthy".
   `flaky_health`, the fleet profile for that, waits for those slices; `bad_release` is built.
2. **What the controller remembers is in memory.** Readiness clocks and death counts start empty
   when a server starts, so a restarted server judges from what it sees afterwards. That can only
   delay a rollout, never hurry one. The phase, the evidence window and the budget's basis are in
   the record (`docs/keys.md`, `/rollouts/<service>`), so another server goes on where this one
   stopped.
3. **A restart is a death.** A replica is replaced under a new id, never restarted in place, so
   "restarts" in `rollout_restarts_max` counts new replicas whose container ended for a reason the
   release can cause (not a held start, which fails at once, and not a lost node).
4. **A held replica fails a resumed rollout again at once** (changes slice 6). Slice 6 judged a
   resumed rollout on evidence newer than the resume only. A held replica is not a past event: it
   is never replaced within its generation and keeps its slot, so a rollout resumed with one still
   held could end only at its deadline, with one replica too many meanwhile (sim-c3 seed 63,
   `--profile=bad_release`: "a service lacks replicas"). `rollout_plan.failure_of` now returns
   `.held` whenever `Facts.new_held_at_ms` is set, whatever the window; its test and the fuzz
   model changed with it. The way out of a held release is a new apply (or slice 8's rollback).
5. **A halted rollout keeps its surge.** While a rollout is paused or failed and has stale
   replicas, the replica controller's scale-down keeps up to `replicas + max_surge`, not
   `replicas`: otherwise a pause would delete the new replica it paused on, which is the step it
   was asked to keep. R2 allows the same bound.
6. **A scale down while paused is allowed.** The user may lower `replicas` during a pause; R4
   exempts a scale down the service asked for and judges only starts and retirements.
7. **Old replicas that stop are dead, not retired.** An old replica that ends by itself during a
   rollout is replaced at the new spec (the `replace` path), without spending the retire budget,
   since nothing was retired.
8. **No auto-rollback yet.** `on_failure: rollback` behaves as `fail` until slice 8 (R5 with it).
9. **`grace_ms` is not plumbed.** Retired old replicas stop with the agent's existing stop grace;
   `rollout.grace_ms` is validated and stored, not used.
10. **A stall becomes ZC-E0305 by remapping.** `rollout_plan.pass` reports a passed deadline; the
    controller turns `deadline` into `stalled` when the plan could not place a start, so the code
    is E0305 as slice 6 decided.
11. **R1 compares observed records.** The budget is spent against the counter and the rollout
    record it was computed on (`budget_revision`, `budget_next`, `budget_old`); R1 judges a
    retirement over the observed records the transaction compared, so a retirement judged on a
    stale report shows.
12. **R names collide with B3's.** B3's relay checks are R1 and R3 too, so the sim-c3 teeth expect
    full-text symptoms (`R1: a retirement`, `R4: a paused rollout`, `R6: a history`).
13. **`auto`'s profile draw changed.** `ClusterProfile` gained `bad_release` with weight 2, so a
    `--profile=auto` replay line written before this slice draws another profile. Replay lines
    name the concrete profile, so recorded lines are unaffected.
14. **The fleet has no `sim-c3` kind.** The three teeth are left out of the canary manifest, and
    neither `sim-c3-teeth` nor a `--c3` seed is in `zig build check`; the gate is the sweep
    `sim_cluster --seeds 1..40 150 --c3` run by hand.
15. **A finished rollout is not deleted after a retention period.** It stays until the next apply
    replaces it.
