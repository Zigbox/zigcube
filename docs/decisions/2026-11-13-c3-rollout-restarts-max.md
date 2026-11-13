# C3: `rollout_restarts_max` is 3, and slice 7 owns the check

*Decided 2026-11-13, by the supervisor, on the question slice 6 left open
(`2026-11-13-c3-slice6-rollout-plan.md`, item 2).*

**The bound.** `rollout_restarts_max` = 3: a new replica that restarts more than 3 times during a
rollout fails the rollout (ZC-E0304, `Failure.restarts`), as the brief says (docs/briefs/c3.md,
"Controller design": "a new replica ... restarts more than `rollout_restarts_max`").

**Who checks it.** Slice 7, not slice 6. The check needs each new replica's restarts counted from
the moment the rollout (or its last resume) began, which means a baseline per replica taken from
the observations the rollout controller reads; `rollout_plan.zig` is pure and sees only the
controller's verdict. So slice 6's code takes the verdict as `Facts.new_restarts_exceeded_at_ms`
(when the controller saw a new replica pass the bound) and adds no constant. Slice 7 adds
`rollout_restarts_max` to `src/constants.zig` with this value, counts restarts against it, and
names it in E0304's explanation and `docs/keys.md` in the same change, as REVIEW.md asks of a
bound.

Where: `src/rollout_plan.zig` (`Facts`), slice 7's rollout controller.
