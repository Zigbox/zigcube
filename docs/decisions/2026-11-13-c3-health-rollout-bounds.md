# C3: upper bounds on health and rollout times, and the blame of W0304 and W0305

*Decided 2026-11-13, by the slice (C3 slice 5 fix), under the supervisor's instruction to take
bounds from existing constants of the same kind. Proposed to the owner in the slice's report.*

## Bounds

Review A of slice 5 found that `health` and `rollout` times had lower bounds and nesting rules but
no upper bound. Every field is a `u32` of milliseconds, so nothing overflows (the "2^63" case
cannot be written), but a service could ask for a 49-day probe interval or a 49-day stop grace.
STYLE.md: every bound is named. Each new bound is an existing constant of the same kind, so none
is a new number:

| Field | At most | Taken from | Why that one |
| --- | --- | --- | --- |
| `health.interval_ms`, `health.start_period_ms` | 1 hour (`health_interval_ms_max`) | `lost_grace_ms_max` | the longest the cluster leaves a replica unjudged elsewhere: how long a lost node may stay lost before its replicas are replaced |
| `threshold × interval_ms`, for each threshold | 1 day (`health_verdict_ms_max`) | `job_deadline_ms_max` | the longest time to a verdict the server waits for anything: a job's longest deadline |
| `rollout.progress_deadline_ms` (and so `ready_timeout_ms`, `min_ready_ms`, which nest under it) | 1 day (`rollout_deadline_ms_max`) | `job_deadline_ms_max` | a rollout is a deadline-bound piece of work like a job |
| `rollout.grace_ms` | 1 minute (`rollout_grace_ms_max`) | `job_grace_ms_max` | the same thing: how long a container gets between the stop signal and the kill |

Every bound is inclusive. Above one, the apply is refused with the field's existing code
(ZC-E0125 for `health`, ZC-E0126 for `rollout`), naming the field and the bound; no code is new.
The defaults (`grace_ms` 10 s, `progress_deadline_ms` 10 min) are well inside them.

If the owner wants other values, only `src/constants.zig` and the E0125/E0126 explanations
change.

## Blame of W0304 and W0305

The brief names the two warnings (rollout paused by `on_failure`, rolled back automatically)
without their blame. Both are `user`: each is the consequence of a rollout failing with ZC-E0304
(a new replica did not become ready: the release is at fault) or ZC-E0306 (the progress deadline
the user's policy set passed), both `user`, and each follows the `on_failure` the user chose. A
rollout that cannot place a replica (ZC-E0305, `environment`) stalls and continues by itself; it
neither pauses nor rolls back. A stall that outlasts the progress deadline does end as ZC-E0306;
that is the one path on which the environment shares the fault, and the user's deadline is still
what decided it, so the blame stays `user` and E0305 in the decision's history says why.

Where: `src/constants.zig`, `src/apply.zig` (`validate_health_bounds`, `validate_rollout`),
`src/diag/codes.zig` (E0125, E0126, W0304, W0305), `docs/keys.md` (`/services`).
