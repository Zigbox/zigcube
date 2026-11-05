# B1: the job controller must never create a second run of a job (open owner question)

*Open 2026-11-05, raised by the review of slice 1 (PR #98). The rule below is not in question;
how the controller knows is. Slice 3 builds the controller after the owner answers; if none comes,
it follows the recommendation and says so in its report.*

## The rule

The brief's controller step 1 says: "create the run and status when a job has none". Read
literally, a job whose `/job-runs/<name>` and `/job-status/<name>` are deleted (by an operator
fixing a contradiction, a bad restore, a hand edit) has none, and is run again. That breaks
authority.md I8a ("a run id has at most one claim, ever"; "never started twice"), and it breaks it
silently: the first run may have finished, and its ending is gone with its status.

So the controller must create a run only for a job that has never had one. It must not
re-create one for a job that had, whatever the cause of its absence. ZC-E0307 says "never delete
a run or a status" for this reason.

## The open part

"Never had one" needs a durable fact that outlives the run and the status. Candidates:

**A. The `job-created` decision (recommended).** Step 1 already writes a decision, `job-created`,
in the transaction that creates the run (decisions are immutable and every role may write them).
Before creating, the controller reads the job's decisions (`/decisions-by-subject/job/<name>`);
a `job-created` there means a run existed: the job is contradictory (ZC-E0307), nothing is
created. Needs no new key and no change to the API's records. Cost: the check reads the decision
index on each creation (once per job, bounded); the decisions of an ended job must live at least
as long as its other records, which retention must respect (it deletes them in the same
transaction, or later, never earlier). If the decision has been dropped by the decision cap, the
rule fails open; slice 3 must show the cap cannot drop a live job's decision.

**B. A marker in the job record.** `/jobs/<name>` gains `run_created_at_ms`. The API is its
writer (I4), so the controller cannot set it; the API would write it only by creating the run
(a role the owner gave to the controller), or the field is set at POST and means "a run is due",
which does not say that one was made. Changes the immutable spec record. Not recommended.

**C. A tombstone key.** The controller writes `/job-runs/<name>` once, and retention is the only
role that may delete it, always together with `/jobs/<name>`. Then a run absent while `/jobs/` is
present is, by construction, never legitimate: the controller creates only if the job is younger
than its start backstop *and* the creation compare (absence of both) holds. A hand edit inside
that window still re-runs the job, so it bounds the hole but does not close it.

**D. Make the absence impossible to act on.** The API creates the run and status in the POST
transaction (an `api` write of `/job-runs/` and `/job-status/`), and the controller never
creates, only advances. Closes the hole completely, but moves a writer: authority.md I4 and the
brief's writer table change, which are Ask-first.

## Recommendation

A, with slice 3 owning the test: a job with a `job-created` decision and no run is E0307 and is
never started (a negative test in `sim-c1`, brief J-checks, and a unit test of step 1). If the
owner prefers a closed hole over a bounded one, D.

## What slice 1 did

Nothing in the records can say it: it wrote the E0307 text (never delete a run or status, and
why), authority.md §7 (the rule), and the slice-3 handoff in `docs/briefs/b1-1.md`.

Where: `src/diag/codes.zig` (E0307), `docs/authority.md` §7, `docs/briefs/b1.md` ("The job
controller", step 1), `docs/briefs/b1-1.md`.
