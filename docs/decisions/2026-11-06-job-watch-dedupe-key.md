# The dedupe key of a job ending: an assumption awaiting owner confirmation

Status: **assumption, not implemented.** Found by the review of #139 (docs/api.md, "GET
/v1/jobs/watch"); needs the owner's word because closing it changes the public row shape.

## The collision

The client contract (b1.md line 348, api.md) deduplicates endings by `(name, epoch)`. A job that
ends unplaced (cancelled or `not_started` before a claim) has `epoch: null`. After retention
(1 h floor) a name can be created again and end unplaced again: the second ending has the same
key `(name, null)`, so a client with durable dedupe records drops it as a duplicate.

## Choice and why it is not made here

Smallest closing change: define the key as `(name, epoch, ended_at_ms)`. `ended_at_ms` is in
every terminal status already (events carry it in `status`), is set once at the ending, and
cannot repeat for one name because reuse is at least `job_finished_age_ms_min` later. The list
row (`Row` in `src/job_api.zig`) does not carry it today, so a client that resumes from a list
could not build the key: closing the gap needs one additive row field `ended_at_ms` and a
changed sentence in api.md. That edits the API contract, so it is left for the owner.

## Until then

Placed endings (every ending that ran) are unique by `(name, epoch)`: the epoch is a store
revision. Only unplaced endings of a reused name can collide, and only for a client that is
durable across more than an hour. J4 in the simulation keys by `(name, epoch)` and does not
reuse names, so it neither shows nor hides this.

Owner: confirm `(name, epoch, ended_at_ms)` plus the additive `ended_at_ms` row field, or name
another key.
