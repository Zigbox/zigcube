# The observation sweep resumes, and a held job with no run frees its slot (#177)

*Decided 2026-11-08, by the #177 implementer, under the supervisor's calls in
`2026-11-08-slice2-flag-calls.md` (which this follows up and does not edit).*

## The `/job-observed/` sweep is a resumable cycle (RB-N7)

Before, retention read at most `observed_pages_max` (64 pages, 32,000 keys) of `/job-observed/`
from the first key on every pass. A stray observation (a node that lost the claim leaves one
behind) past the cut was never deleted, and was orphaned for good once its job went.

Now `Cursor` keeps where the sweep stopped (`observed_after`). A pass reads from there, deletes
the observations of every job that was old when the cycle began (each delete compares the
observation's revision, so a claim written after the read stays; at most
`observed_sweep_txns_max` transactions a pass), and a pass that stops short says so (ZC-E0302)
and is due at once. A cycle that reads to the last key records its start time (`swept_ms`).

A job is dropped only if it was old at `swept_ms`: only then did every window of that cycle see
it as old and sweep its strays. Until the first cycle ends nothing is dropped. When the whole
prefix fits in one pass (the normal case) the cycle ends in the pass that began it and nothing
changes. With more than 32,000 observations, retention of old jobs waits for the cycle: a few
passes, each due at once. Ended jobs' observations are still kept until the job is old (`why`
reads them as evidence). A stray written after its cycle's window passed it (a loser reporting
late) is swept by the next cycle only if its job is still there; that remaining edge is not
closed.

## A held job with no run frees its `jobs_max` slot

`admitted - ended` charges a job against `jobs_max` until `/job-endings` counts it, and a
ZC-E0307 job never reached `end()`. Deleting its keys by hand did not help either: the count
only moves in `end()`. Now the `hold_contradictory_job` transaction counts the job as ended
when it has **no run** (neither record, or a status alone): such a job never started and, by
I8a, never will. Once per incarnation of the job: a later hold for another revision of the
record finds the earlier hold decision and counts nothing.

A job that has a **run without a status** keeps its slot: its run might be placed, and
releasing the slot could take live jobs past `jobs_max` (and `assigned_max`). That case still
needs an operator, and a deleted-by-hand job of that kind still leaks its slot. If an operator
restores the missing run of a job that was already counted, its later ending counts it a second
time; `live` then under-counts by one for that job. Both are corruption cases, accepted.
