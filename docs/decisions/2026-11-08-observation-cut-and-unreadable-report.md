# The observation cut, resumed; an unreadable report no longer holds a run

*Decided 2026-11-08, by the implementer of #177, with the supervisor's approval of the bounds.*

Supplements `2026-11-08-slice2-flag-calls.md` (merged, not edited). Its item 2 accepted a cut
sweep that restarted from the first key on every pass, with the resume cursor left to #177.

1. **The observation cut.** The cursor is in: the sweep resumes across passes, and a job is
   dropped only when it was old at the start of the cycle that read to the end (RB-N7). The cut
   itself (64 pages a pass, ZC-E0302 when a pass hits it) stays, and is recorded in
   `docs/demos/c1.md`, "Cuts", as that decision said it would be.
2. **RB-S8, an unreadable report.** The job controller used to return at the hold, so with a
   corrupt report a cancel wrote no stop and a lost node never ended the job (the #175
   re-review). An unreadable report now counts as no report once its hold decision is written:
   - a running run is judged as ever (cancel writes the stop; lost past the grace: `failed
     unreachable`);
   - a run not yet running gets the cancel's stop, or an `unreachable` stop once its node is lost;
   - with a stop written and the node lost past the grace it ends `failed unknown` (cause
     `unknown`, stop cause kept), as a stopped report that maps to no ending does: it may have
     started and nothing readable says how it went. `cancelled` and `not started` would claim
     more than is known.
   - while the node is alive the run waits: its next report replaces the unreadable one.

Where: `docs/keys.md`, `docs/api.md` and `docs/authority.md` (`hold_unreadable_job`);
`docs/demos/c1.md`.
