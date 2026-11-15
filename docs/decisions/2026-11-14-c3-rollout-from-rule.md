# C3: a rollout's `from`, contradicting records, and refused automatic rollbacks

*Decided 2026-11-14 by the supervisor, after the review of the slice 6 fix for the TLA+ model's
finding 8 (`2026-11-14-c3-first-generation-failure.md`). Recorded by the slice 6 fix session.
Binds slice 7 (the rollout controller) and slice 8 (`sim-c3`).*

**1. `from` is the generation the service last ran to completion:** the target of the newest
rollout that ended `complete`, 0 if none. An apply made while an earlier generation is still
progressing, or over a failed first generation, therefore has `from` 0 (or the last generation
that completed), never a generation that never became ready. So an automatic rollback never
targets a release that never ran. `begin`'s `earlier` is `from != 0`.

**2. A stored `/rollouts` record that contradicts itself is refused when decoded, with a coded
diagnostic, never asserted on.** The existing code fits: ZC-E0301 ("a stored record can't be
read": not a record of the kind its key says), so no code is registered. Slice 6 already does
what the record holds today: `records.read(Rollout, ...)` refuses `to` 0, `from` not below `to`,
`deadline_at_ms` before `started_at_ms`, and `rolling_back` with `from` 0 (`rollout_valid`, test
"C3: a rollout record that contradicts itself is refused when read"). Slice 7 adds `reason`,
`paused_at_ms`, `paused_by` and `evidence_from_ms` to the record (slice 6 decision, item 5) and
must extend `rollout_valid` to everything else `State.assert_valid` and `begin` assert: `reason`
rollback with `from` 0, `paused_at_ms`/`paused_by` set exactly while `paused`, `evidence_from_ms`
not before the start, a pause not before the evidence, an active phase that is not the reason's.
It does this before it calls `begin` or `pass`; the controller then changes nothing for that
service until the key is fixed (ZC-E0301's own fix line).

**3. An automatic rollback that the rollback handler refuses (ZC-E0127, ZC-E0128) ends the
rollout `failed`, owing nothing, with the refusal recorded** as the decision's code. With rule 1
the handler should not refuse, but the history can lose the generation (16 kept) or a record can
be hand-edited. `pass` has no input for this yet: its "owes a rollback" is a function of the
state alone (`rollback_owed`), and the record holds nothing that says "refused". That is slice 7's
obligation: add an optional record member (for instance `rollback_refused: bool`, additive like
item 5's), a matching `State` field that `rollback_owed` reads as owing nothing, and a `pass`
test; so that a future `sim-c3` R7 check can script a refused rollback and see the rollout end.

**R7 under `on_failure: pause`.** A failing rollout waits in `paused` for an operator (ZC-W0304).
That is not an end and R7 does not count it as one: slice 8's check holds such a rollout to the
same bound for reaching `paused` (paused by a failure counts as settled), starts the bound again
from a scripted resume, and stops the clock during a user's pause.

**Open question for the supervisor:** none needs a new code. If slice 7 prefers a code of its own
for a contradicting rollout (as jobs have ZC-E0307), that is a registration to ask for, not to
make.

Where: `src/records.zig` (`rollout_valid`), `src/rollout_plan.zig` (`pause_rollout`'s comment; test
"a first generation keeps owing nothing across pause and resume", which also catches the mutation
"`resumed` sets `.earlier = true`" without the fuzzer), `docs/keys.md` (`/rollouts`),
`docs/briefs/c3.md` (R7, the record, the controller design), `src/diag/codes.zig` (W0304).
