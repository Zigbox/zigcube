# The C3 bundle: how the held slices were merged

Date: 2026-11-15. Branch `claude/bundle-c3`, from `main` 65e6ece, merges only (no rebase).

## Merged

In dependency order: `claude/c3-slice7-controller` (slices 5, 6, 7), `claude/c3-slice11-surfaces`
(slice 11), `claude/c3-slice10-probe` (slices 9, 10), `claude/c3-slice4-soak` (slices 2, 3, 4),
`claude/c3-slice15-macos` (slice 15) and `claude/jepsen-teeth-fence-stop`. Already on `main` by
squash and so skipped: `c3-fleet-1` (#77), `c3-fleet-canary` (slice 1, #97), `c3-fleet-i3` (#81,
with its ttl floor superseded by #124) and `c3-brief`. The I3 branch's decision file
`2026-11-05-i3-inadmissible-observations.md` was not on `main`; it is carried here.

## Choices made in the conflicts

- **Slice 11 follows slice 7's records.** Slice 11 was written against slice 5's rollout record
  (an optional `reason`, a `RolloutPausedBy` type, its own `state_of`). Slice 7 settled them
  (`reason: RolloutReason = .apply`, `RolloutPauseCause`, `rollback_refused`, the budget members).
  The API's pause and resume (`src/rollout_steer.zig`) now read the state with
  `rollout_controller.state_of` and write it with `rollout_controller.write_state` (made `pub`),
  reset the budget, clear `next_at_ms` on a pause, and answer ZC-E0129 when the record is not for
  the service's generation (`rollout.to != service.generation`). A record slice 7 could not have
  written (paused without its members) is ZC-E0301 at read, as slice 7's reader says.
- **Two writers of a pause.** `rollout_controller.request` (the simulation's, `sim_cluster.zig`
  `request_rollout`) and `rollout_steer.steer` (the API's) both write a pause or a resume. They now
  write the same state, but the simulation does not go through the API's handler. Follow-up:
  make the simulation call the API path, so R4 judges what users run.
- **The health stage no longer ends the agent's pass.** Slice 10 returned after a failed health
  stage (`if (kept.stopped) return acted;`); `main` (#247) runs the job pass even after a replica
  stage's server failure. The bundle keeps #247's rule: a failed health stage stops the replica
  stages through `stopped`, and the job pass still runs.
- **Teeth.** `c1_teeth.any` keeps `main`'s job teeth and the soak's `soak_leak`; the three rollout
  teeth and `fence_stop_teeth` stay out of it, as their branches had them. `sim-c1-teeth` runs 26
  negative runs and `sim-c3-teeth` 3.
- ZC-E0301's explanation joins both branches' causes (naming, a health check out of bounds, fields
  that contradict each other); `site/errors/` and `web/mock/codes.js` were regenerated.
- Two functions grew past 70 lines in the merge (`operation`, `simulate` in `sim_cluster.zig`);
  the job arm and the world setup moved into `job_create` and `start_worlds`, with no change in
  behaviour (the same draws in the same order).

## Left out

Linux packages (slices 13 and 14, `c3-linux-packages.md`) went to the B7 bundle
(`claude/b7-packaging*`) and are not here.
