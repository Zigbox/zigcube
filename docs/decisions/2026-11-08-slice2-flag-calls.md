# The supervisor's calls on B2 slice 2's flags (#175)

*Decided 2026-11-08, by the supervisor.*

The slice 2 implementer flagged four things. Each call, with its reason:

1. **Controller instance cap 8191.** `controller_instance_max` shrinks the restart-uniqueness
   cycle from about 16.7 h to about 2.3 h. Accepted. A decision id carries `at_ms`, so a collision
   needs the same instance, the same millisecond and the same counter. The real hazard is that
   `put_decision` writes `/decisions/<id>` without a compare-absent, so a collision would
   overwrite an audit record silently; that hardening is #177.
2. **RB-N7, `job_retention` is not a full resume.** The scan that deletes stray observations is cut
   at `observed_pages_max` (64 pages, 32,000 keys) and starts from the first key on every pass.
   Accepted for B2: it takes more than 32,000 observations to matter, against roughly
   `job_admitted_window_max` (8,192) plus strays in practice, and the cut is reported with a
   diagnostic. A resume cursor is #177.
3. **`hold_unreadable_job`** is documented by slice 3 (PR #178), not here.
4. **A ZC-E0307 contradictory job never frees its `jobs_max` slot.** Accepted for B2; follow-up
   #177.

Also on record: seed `111 200 --c1` (J8) fails identically on `main`, so it predates #175.

Where: `docs/briefs/b2.md` (slice 2); `docs/demos/c1.md` for the observation cut.
