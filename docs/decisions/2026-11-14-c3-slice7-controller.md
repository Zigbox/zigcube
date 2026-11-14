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
   model changed with it, and so did slice 6's later test "a first generation keeps owing
   nothing across pause and resume" (merged from the from-rule fix). The way out of a held release is a new apply (or slice 8's rollback).
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
    neither `sim-c3-teeth` nor a `--c3` seed is in `zig build check`. CI's `sim` job runs both
    the gate's sweep, `sim_cluster --seeds 1..40 150 --c3` (about a minute), and `sim-c3-teeth`.
15. **A finished rollout is not deleted after a retention period.** It stays until the next apply
    replaces it.
16. **A replacement made during a pause keeps the old generation** (TLA+ review, gap 2). An old
    replica that ends while its rollout is paused or failed is replaced at its own generation
    (`replica_controller.create_replicas_from`), so a pause starts nothing new; R4 checks that no
    paused step creates more new-generation replicas than died. While the rollout is active the
    replacement runs the new spec, as item 7 says.
17. **What a retirement compares** (TLA+ gap 1, finding 7): the "recheck" reading, with the floor
    compared exactly while it fits in a transaction and as far as it fits past that;
    `docs/decisions/2026-11-14-c3-rolling-floor-compares.md`. Every write of `/rollouts/<service>`
    and every retirement compares the rollout record's revision, so a pause between a read and
    a commit fails the commit.
18. **`State.earlier` comes from the record** (slice 6's 4d4ec68, merged): a rollout ran before
    when it is a rollback or its `from` is not 0. Slice 7 calls no rollback (item 8); slice 8 must
    not roll back a rollout whose `from` is 0, since there is nothing to go back to.
19. **`from` is the generation that last completed** (supervisor ruling a,
    `2026-11-14-c3-rollout-from-rule.md` rule 1, merged from slice 6's branch).
    `rollout_controller.Run.from_of`: the previous rollout's `to` if it ended `complete`, else its
    `from`. One addition the rule does not state: a service's first generation has no rollout of
    its own, so with no rollout of the service (or only one of a deleted incarnation) `from` is
    the newest generation below the service's that its old replicas run
    (`View.earlier_generation`). Taken literally ("0 if none"), the rule would make every second
    generation's `from` 0, and no rollout would ever owe a rollback. An old replica at the
    service's generation or above belongs to a deleted incarnation or runs another spec of the
    same generation, and is no earlier generation, so `from` stays below `to`. `docs/keys.md`
    says the same.
20. **A `/rollouts` record that contradicts itself is ZC-E0301 at decode** (rule 2): slice 6's
    `records.rollout_valid` now also refuses what `State.assert_valid` and `begin` assert on the
    members slice 7 added (a rollback from 0, `paused_at_ms`/`paused_by` set exactly while
    `paused`, `evidence_from_ms` before the start, a pause before the evidence, an active phase
    that is not the reason's), tested with record text the controller wrote. No new code.
21. **Rule 3: a refused auto-rollback is an end** (the supervisor's later message assigns it to
    slice 7). `/rollouts` gains the optional member `rollback_refused` (`true` or absent),
    `rollout_plan.State.rollback_refused` mirrors it, `rollback_owed` owes nothing once it is set,
    and `rollout_plan.rollback_refused` sets it on a rollout that owed one; a pause clears it.
    Test "a refused automatic rollback ends the rollout, owing nothing". The record refuses the
    mark on anything but a failed `apply` (ZC-E0301). Slice 7 calls no rollback handler (item 8):
    slice 8 calls `rollback_refused` when the handler answers E0127 or E0128, records the code in
    the decision and writes the state once.
22. **W0304's fix line** says "roll back (if it ran an earlier generation)", like its
    explanation (`cli_golden.zig` and its three golden files; the controller's `rollout_pause`
    decision has no fix line of its own).
