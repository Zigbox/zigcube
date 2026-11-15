# C3: a failed first generation ends `failed`, owing no rollback

*Decided 2026-11-14, by the slice 6 fix session, for the supervisor's review.*

**The finding.** The TLA+ model of the rollout (zigcube-tla PR #3, `Rollout.tla`, FINDINGS.md
item 8, config `finding-rollout-first-generation`) found a rollout that never ends: a service's
first generation fails under `on_failure: rollback` (the default). `rollback_owed` held (failed,
policy `rollback`, reason `apply`), so the controller would call the API's rollback handler on
every pass, but `from` is 0: there is no earlier generation, the handler refuses with ZC-E0127,
and the rollout stays `failed` owing a rollback forever. Item 4 of
`2026-11-13-c3-slice6-rollout-plan.md` knew the case and relied on a user's pause to hold it, so
R7 ("reaches `complete` or `failed`-then-rolled-back") failed as worded.

**The choice: owe no rollback, end as `failed`.** The other option, treating the case as a pause,
was rejected: `paused` is not an end state (R7 does not count it), it says "waiting for you to
resume" when resuming cannot help (the evidence is not new, the release is), and W0304 would say
the policy was `pause` when it was not. Ending `failed` owing nothing is what a failed rollback
already does (slice 6 decision, item 3), so a `failed` rollout that owes nothing now means one
thing: the rollout ended, and the user's next apply starts the next one.

- `rollout_plan.State` gains `earlier: bool`: the service ran a generation before the rollout's
  target (the `/rollouts` record's `from` is not 0). `begin` takes it; a rollback always has one
  (asserted). `rollback_owed` is false without it, so `Pass.rollback` is never set and a later
  pass of the failed rollout changes nothing and plans nothing.
- The record needs no new member: slice 7 passes `from != 0` to `begin` and rebuilds the field
  from `from` when it reads the record back.
- Under `on_failure: pause` nothing changes: the rollout pauses, as any does.
- No code is registered and no default changes. The failure's own code (E0304, E0305 or E0306)
  is still recorded; no W0305 follows, since nothing was rolled back. The E0304 and E0306
  explanations now say a failed first generation stays failed.
- R7 in `docs/briefs/c3.md` reads: `complete`, `failed`-then-rolled-back, or `failed` owing no
  rollback (a failed rollback, or a failed first generation). `sim-c3` does not exist on this
  branch; its R7 check (slice 8) must count that end state and should script a failing first
  generation.

Tests: `rollout plan: a failed first generation under on_failure rollback ends` (fails without the
fix: the pass owes a rollback; it fails each of held, restarts, ready timeout and deadline, passes
again long after, and checks `on_failure pause` and a later generation), and the fuzzer's model,
which begins one apply in four (and the first rollout half the time) with no earlier generation.

Where: `src/rollout_plan.zig`, `src/rollout_plan_fuzz.zig`, `src/diag/codes.zig` (E0304, E0306),
`docs/briefs/c3.md` (R7, controller design), `docs/keys.md` (`/rollouts`).
