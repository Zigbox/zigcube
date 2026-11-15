# The rollout's health gate, and `unknown` after an agent restart

Date: 2026-11-15. The rule on `unknown` is the supervisor's (C3 slice 12), given when the
implementer reported the finding; the implementer wrote this record.

## Context

demo-c3's step 3 showed that the rollout controller counted a replica as ready from its status
alone: the health check's verdict never reached it (slice 10's placeholder in `Track.update` was
not filled in), so a `v3` whose check never passed completed its rollout and retired `v2`. Fixing
that (`f7157f3`, then the replica controller's `running_healthy`) raised a second question: an
agent restart reports every replica's health `unknown` until it probes again (slice 9). If
`unknown` means "not ready", a restart during a rollout makes every old replica on that node free
to retire as unready (`budget.retire_unready`), and the rollout takes the service below its floor.

The brief defines readiness (`docs/briefs/c3.md`, "Settled here": a replica is ready when its check
has passed `success_threshold` times in a row and it has stayed healthy for `min_ready_ms`) but
says nothing about `unknown` after `healthy`.

## Decision

- A replica with a health check is ready only on `healthy` reports held for `min_ready_ms`;
  `unhealthy` is never ready.
- **An old replica** (one the rollout replaces) that runs and whose health is `unknown` counts
  as running to both controllers, whether or not it was ever healthy: the rollout controller keeps
  its `running_since_ms` through `unknown` (or starts it, for one never healthy), and the replica
  controller counts a stale replica whose health is `unknown` as running, so it is retired only
  within `budget.retire` and above the floor, never as unready.
- **A new replica** counts as ready only on `healthy`: while it is `unknown` after `healthy` it is
  not ready, though its time is kept, so it is ready again as soon as it reports `healthy`. This
  departs from the brief's readiness row ("stayed healthy for `min_ready_ms`", timed from the
  transition the controller saw): time spent `unknown` after `healthy` counts toward
  `min_ready_ms`, though nobody saw the replica healthy then (PR #261 re-review, NIT; kept as the
  supervisor's rule).
- A new replica's `unknown` that follows anything but `healthy` (not yet probed) is not ready.

## Consequences

- The replica controller is stateless, so it counts every stale `unknown` as running, including an
  old replica that was never healthy, and the rollout controller does the same, so the two agree.
  An earlier version of this rule (a98f400) made the rollout controller count a never-healthy
  stale `unknown` replica unready: it offered the replica to `budget.retire_unready`, the replica
  controller kept it for `budget.retire`, and a rollback over a release whose checks never settle
  (every probe refused, ZC-E0516) stayed `rolling_back` for good (PR #261 re-review, MUST). Such a
  replica is now ready to the rollout controller `min_ready_ms` after it became old, and is retired
  within `budget.retire` once the new replicas are ready; until then the rollout controller counts
  it unready and the replica controller keeps it, which delays the retirement and never loses it.
- The controller's memory does not survive a server restart; after one, every replica waits
  `min_ready_ms` again, as before.
- Tests: `src/rollout_controller_test.zig`, "an agent restart's unknown keeps old replicas ready
  and new ones not ready" (without the change, all three old replicas are retired at once),
  "an unhealthy replica of a failed rollout is retired as not ready by the rollback", "a
  never-healthy replica of a failed rollout whose checks never settle is retired" (fails if the
  rollout controller counts a stale `unknown` unready), "a new replica unknown after healthy is
  not ready to the rollout controller" (fails if `view` counts it ready) and "an old replica
  unknown after an agent restart counts toward the replica floor" (fails if `running_healthy`
  counts a stale `unknown` not running). No
  simulation tooth: `sim-c3`'s R1 counts running replicas, not healthy ones, so a controller that
  ignores health fails no simulated check; demo-c3's witness counts healthy ones.
