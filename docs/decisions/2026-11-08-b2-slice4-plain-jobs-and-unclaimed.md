# B2 slice 4, part 1: job checks in plain runs, J4 coverage, J8's unclaimed clause

Decided 2026-11-08 by the slice 4 implementer; part 1 of the slice only (see the handoff below).

- **Job checks run without `--c1` (RB-S2 a, e).** `tapped` feeds `sim_jobs_watch.note_commit` and
  `watch_client` runs whenever jobs are on. J2, J4, J6, J7, J8 and J10 need no per-revision
  invariant tap, so every job tooth but `job_double` (whose injection lives in `before_commit`,
  which still needs `--c1`) also runs plain: `plain_symptom` / `plain_seeds` in `c1_teeth_roots`.
  Fail-before: on the base, `job_gap` plain failed 0 of 40 seeds; now 23 of 40.
- **J4 coverage (RB-S2 b).** `covered` runs on every poll: each truth ending whose commit
  revision is at or below the client's revision must be in `handled`. It no longer depends on
  `finish` (run only from `jobs_converged`) or on the 60 s compaction masking a dropped event.
- **J8 second clause (RB-S2 d).** `unclaimed_ended`: a run whose `start_by_ms` passed, which no
  node ever started (not on the J2 ledger) and which is not terminal, fails 90 s after the later
  of `start_by_ms` and the store's last failure. Every 13th job asks for 100,000 millicores, more
  than any node has, so such runs exist (no PRNG draw: other worlds are unchanged). Tooth
  `job_unclaimed` skips the controller's `not_started` end. Hit rate seeds 1..40, 100 ops: 11
  plain, 20 with `--c1`; the symptom is the one expected.

## Not done (handoff)

RB-S2 c (lost state dir: needs `SimState.wipe` and a check that `load_pair` survives it, then a
J2 tooth), RB-N8 (`wedged_lately`, `watch_max`), teeth for more than 512 runs on a node and for
name reuse, the wider lease ttl draw (a default change: ask first, and then drop the #78 sentence
from AGENTS.md), the slow `--c1` seeds 12 19 27 44 69 (profile first), #136 and #152 replay and
close, the `ops/sim-fleet/README.md` canary table, and the merge of `origin/main` and
`origin/claude/b2-i1b-fencing`.
