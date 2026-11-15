# C3 slice 6: what the rollout plan decides, and what it leaves to slice 7

*Decided 2026-11-13, by the slice (C3 slice 6, `src/rollout_plan.zig`), for the supervisor's review.*

`rollout_plan.zig` is the pure half of the rollout controller: the budget and the phase machine,
in the core list, with no store and no clock of its own. Choices the brief left open or that
differ from it:

1. **A stall (ZC-E0305) is reported, not a failure, until the deadline.** The brief lists
   "surge cannot be placed" among the failures; E0305's registered explanation says the rollout
   "continues by itself once a replica can be placed", and its blame is the environment, not the
   new version. Rolling back a good version because the cluster is full would be wrong. So `pass`
   sets `stalled` when the plan has a start to make and the controller says nothing fits, and the
   phase stays where it is. If the rollout is still stalled on the pass that finds
   `progress_deadline_ms` passed, it fails as `Failure.stalled`, whose code is **E0305**
   (environment), not E0306: the decision slice 7 records, and the W0304 or W0305 that follows,
   cite the stall, not the user's release. `on_failure` still applies, so R7 (complete, or failed
   then rolled back) holds; the E0305, E0306, W0304 and W0305 explanations say so. This supersedes
   the paragraph of `2026-11-13-c3-health-rollout-bounds.md` that kept such a stall as E0306.
2. **The restart bound is not a number here.** `Facts.new_restarts_exceeded_at_ms` takes the
   controller's verdict; the bound (`rollout_restarts_max`, 3) and the counting are slice 7's:
   `2026-11-13-c3-rollout-restarts-max.md`.
3. **A failed rollback is not rolled back, and ends `failed`.** A rollout begun as a rollback
   (`State.reason = rollback`) that fails goes to `failed` under `on_failure rollback`, owing
   nothing (`rollback_owed` is false), so a version pair that both fail cannot swap forever and the
   rollout still ends (R7) instead of waiting in `paused` for an operator. Under `on_failure pause`
   it pauses, as any rollout does. `Pass.rollback` is set exactly when `rollback_owed` holds: the
   rollout failed, the policy says `rollback`, its reason is `apply`, and the service ran an
   earlier generation (`State.earlier`; a failed first generation ends `failed` the same way:
   `2026-11-14-c3-first-generation-failure.md`).
4. **Pause and resume.** Pause is allowed from `progressing`, `rolling_back` and `failed`;
   pausing a paused rollout changes nothing; pausing a `complete` rollout is refused
   (`error.NoRollout`, ZC-E0129). Pausing a `failed` rollout stops a rollback it owes. (This item
   once relied on that pause to hold a failed first generation, which would otherwise stay `failed`
   calling a rollback handler that refuses it; the TLA+ model showed R7 failing there, and such a
   rollout now owes nothing: `2026-11-14-c3-first-generation-failure.md`.) Resume is
   allowed from `paused`, changes nothing on a running rollout, and is refused on `complete` and
   `failed`. ZC-E0129's explanation now says exactly this: the idempotent cases succeed.
   - **A resumed rollout returns to its own phase.** `State.reason` (apply or rollback) names it,
     so a paused rollback resumes as `rolling_back`, never as `progressing`.
   - **A resumed rollout is judged on new evidence only.** `State.evidence_from_ms` is the start,
     then each resume. A held replica or a passed restart bound counts only if the controller saw
     it at or after that moment (hence `Facts.new_held_at_ms` and `new_restarts_exceeded_at_ms`,
     timestamps instead of booleans), and a ready timeout counts from the later of the replica's
     first unready sighting and that moment.
   - **The deadline.** `State.paused_by` says whether the user paused the rollout or a failure
     did (`on_failure pause`, or a pause of a `failed` rollout). After a user's pause the deadline
     moves by the paused time (the brief). After a failure's it starts again from the resume
     (`now + progress_deadline_ms`): a rollout paused for passing its deadline would otherwise fail
     again on the next pass.
5. **State the `/rollouts` record does not have.** Slice 7 adds `paused_at_ms`, `paused_by`,
   `reason` and `evidence_from_ms` to the record as optional members (an additive change), since
   resume needs them. `reason` cannot be read from `phase` while the rollout is `paused` or
   `failed`. Slice 6 changes no key.
6. **Unready old replicas are a separate count, in the plan and in the record.** `Plan` holds
   `retire` (ready old replicas, the ones R1 limits) apart from `retire_unready`, and
   `Plan.stored()` keeps them apart: `records.RolloutBudget` gains `retire_unready` (optional,
   default 0; no build writes `/rollouts` yet, so no older text lacks it in practice). A replica
   that turns ready between the plan and the act is therefore never retired on the unready count;
   slice 7's replica controller retires on `retire_unready` only replicas that are not ready when
   it acts.
7. **R1 does not hold for `recreate`,** which retires every old replica before it starts any new
   one. That is the strategy's point. The slice-7 simulation check of R1 exempts it.
8. **Done wins.** If a pass sees the rollout done and a failure at once, it completes. Failures
   are ranked: held, restarts, ready timeout, then the deadline (stalled or not). The first three
   are E0304, a stalled deadline E0305, the deadline E0306.
9. **A newer apply (`begin`) is allowed from any phase,** `paused` and `failed` included, and
   starts a fresh rollout with a new deadline, in the phase its reason names.

The fuzzer (`src/rollout_plan_fuzz.zig`, in `zig build test`) checks the budget against an
oracle written separately from the module. It runs each rollout to `complete` in a model world
where the controller carries out all or part of each budget, with R1 and R2 checked at every step.
It also walks the phases (passes, pauses, resumes, begins and policy changes, one step in eight
taking no time) against `Model`, a phase machine written in the fuzzer from this file and the
brief: after every operation the states, failures, rollbacks, budgets, stalls and next looks must
be equal. The model knows which operation it applied, so a `begin` in the same millisecond as the
step before is recognised (review B's finding; the old oracle read `started_at_ms` back from the
module). The iteration seeds review found, 15358748992189162208 and 16187094404926879864, are
replayed by a test, and a hand-built test runs a begin, pause and resume in one millisecond.

Where: `src/rollout_plan.zig` (header), `docs/briefs/c3.md` (slices 6 and 7).
