# A pause of a failed rollout clears `rollback_refused` (C3 slice 8)

Date: 2026-11-15. Slice 7 review A left an open note: `rollout_plan.paused` clears
`rollback_refused`, so a failed rollout whose automatic rollback was refused (ZC-E0127 or
ZC-E0128) forgets the refusal when it is paused. Should it?

## Decision

It stays: a pause clears the mark.

## Why

- **A pause already stops the rollback.** ZC-E0129's explanation and `pause_rollout`'s comment say
  that pausing a failed rollout stops the automatic rollback it owes. A paused rollout owes
  nothing (`rollback_owed` needs `phase == .failed`), so the mark has no meaning while it is
  paused.
- **A resume is a fresh attempt.** It gives the rollout a fresh deadline and a reset budget. If it
  fails again, it fails on new evidence. The controller then owes the rollback again and asks the
  handler again. Under slice 8, that request is the same `rollback.rollback` a user's
  `zcube rollback` makes. If the history still has nothing to restore, the handler refuses again,
  and the controller writes a second `rollout_fail` decision and marks the rollout again. If an
  earlier generation has appeared since (none can, as generations only grow, but a `to` the
  history no longer holds can), the rollback lands. Either answer is right for the state at that
  moment.
- **No loop.** Each round needs a user's pause and a user's resume, then a whole failure (a ready
  timeout or the progress deadline). The controller never clears the mark by itself.
- **Keeping it would be worse.** A rollout paused, resumed and failed again with the mark kept
  would end owing no rollback, without asking the handler. It would skip the automatic rollback
  the policy asks for on the evidence of an earlier attempt.

## Tested

- `rollout_plan.zig`, "...refuse its rollback, pass it again much later": a pause clears the
  mark, and a resume runs again without it.
- `rollout_controller.zig`, "C3 slice 8: a refused automatic rollback is asked again after
  pause, resume, new failure": the controller refuses once, writes one decision, stays
  quiet on later passes, then after a pause and resume and a new failure asks again and is
  refused again.
