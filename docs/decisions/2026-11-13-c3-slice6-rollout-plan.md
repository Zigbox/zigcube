# C3 slice 6: what the rollout plan decides, and what it leaves to slice 7

*Decided 2026-11-13, by the slice (C3 slice 6, `src/rollout_plan.zig`), for the supervisor's review.*

`rollout_plan.zig` is the pure half of the rollout controller: the budget and the phase machine,
in the core list, with no store and no clock of its own. Choices the brief left open or that
differ from it:

1. **A stall (ZC-E0305) is reported, not a failure.** The brief lists "surge cannot be placed"
   among the failures; E0305's registered explanation says the rollout "continues by itself once a
   replica can be placed", and its blame is the environment, not the new version. Rolling back a
   good version because the cluster is full would be wrong, and `progress_deadline_ms` (E0306)
   already bounds a stall that never clears. So `pass` sets `stalled` when the plan has a start
   to make and the controller says nothing fits, and the phase stays where it is. Slice 7 records
   the E0305 decision from it.
2. **The restart bound is not a number here.** The brief names `rollout_restarts_max`, which
   does not exist yet and would be a user-visible bound: adding it needs the supervisor's word
   (AGENTS.md). `Facts.new_restarts_exceeded` takes the controller's verdict instead; slice 7
   asks for the value.
3. **A failed rollback is not rolled back.** A rollout that began as a rollback and fails goes
   to `paused` whatever `on_failure` says, so a version pair that both fail cannot swap forever.
   `failed` therefore always means "a rollback is owed" (`Pass.rollback`), and with
   `on_failure pause` a failure goes straight to `paused`.
4. **Pause and resume.** Pause is allowed from `progressing` and `rolling_back`; pausing a paused
   rollout, or resuming a running one, changes nothing; pause or resume of a `complete` or `failed`
   rollout is refused (`error.NoRollout`, ZC-E0129). A resumed rollback comes back as
   `progressing`: from there on it is a rollout to the version it names. Resume extends
   `deadline_at_ms` by the paused time.
5. **`paused_at_ms` is state the `/rollouts` record does not have.** Resume needs it to extend the
   deadline. Slice 7 adds it to the record as an optional member (an additive change to the
   record); slice 6 changes no record and no key.
6. **Unready old replicas are a separate count.** `Plan.retire_unready` holds them apart from
   `retire` (ready old replicas, the ones R1 limits), and `Plan.stored()` adds them into the
   record's single `retire`. The record's count is right only if the replica controller retires
   unready replicas first. A replica that turns ready between the plan and the act would then be
   retired outside R1. Slice 7 must either re-check readiness when it acts, or store the two counts
   apart.
7. **R1 does not hold for `recreate`,** which retires every old replica before it starts any new
   one. That is the strategy's point. The slice-7 simulation check of R1 exempts it.
8. **Done wins.** If a pass sees the rollout done and a failure at once, it completes. Failures
   are ranked: held, restarts, ready timeout, then deadline. The first three are E0304 and the
   deadline is E0306.
9. **A newer apply (`begin`) is allowed from any phase,** `paused` and `failed` included, and
   starts a fresh `progressing` rollout with a new deadline.

The fuzzer (`src/rollout_plan_fuzz.zig`, in `zig build test`) checks the budget against an
oracle written separately from the module. It runs each rollout to `complete` in a model world
where the controller carries out all or part of each budget, with R1 and R2 checked at every step.
It also walks the phases and checks each move against the edge table.

Where: `src/rollout_plan.zig` (header), `docs/briefs/c3.md` (slices 6 and 7).
