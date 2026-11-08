# Dispatch order, and #159 before #171

*Decided 2026-11-08, by the supervisor (recorded by the #171 implementer).*

## Decision

- **Free Sonnet slots go to the brief's slices, in the order `docs/briefs/b2.md` lists them,
  before side bugs.** A side bug waits for a slot no slice can use.
- **Before it spawns a session, the supervisor checks the files that session will touch against
  the open pull requests.** Two sessions on one file (here `src/sim_cluster.zig`) fight over
  the same lines and each assumes the other's fix.
- **#159 and #171 merge back to back, #159 first.** The 00:43 call to drop #171's
  `deadline_set` subtraction because #159's clock would fix the step-overrun class is
  superseded by the evidence below.

## What the evidence was

After #159 gave the simulated agent a per-call clock, seeds 1384, 1612 and 893 failed on code that passed on `main`. The first guess was the step-overrun class
(#169, #136): an agent step that runs past the fence. It was not. Two causes, neither of them
that class:

1. **Simulator artefact (seed 1612, I1b "self-fencing failed").** A `crash_now` that lands
   while a node is inside a step's spent time (`resume_ms > manual.ms`). The sim runs a step
   whole at its start, and the step's clock reading and saved lease pair already include the
   time its calls spent (10 s in 1612, a timed-out call). The agent that restarts reads a node
   clock held at that reading until true time catches up, and restores a lease stamped ahead
   of true time, so it fenced about 4 s late. A real agent that dies mid-step has written none
   of that and reads a clock that always moves. Seeds 1384 and 893 had the same restart
   (#159's review traced all three). Fix in the sim, kept: the restart waits until true time
   has caught up with the node's clock (`restart_at_ms = max(restart_at_ms,
   busy_until_true_ms + 200)` in `check_crashed`, the review's alternative), and `step_once`
   asserts that a step starts only once it has (`busy_until_true_ms <= manual.ms`) or while
   its own step is in flight (`resume_ms`). The first fix, arming a `crash_now` inside a
   step's time for the step boundary (`arm_step`), fixed 1384, 1612 and 893 but not the
   other crashes inside a step (`arm_crash`): the assert fired on seed 57 at 100 operations
   under `--c1`. The restart rule covers every crash, so `arm_step` was dropped rather than
   kept beside it. It lengthens only a downtime that would have ended inside the step's time.
   The assert holds under it on 1384, 1612 and 893, plain and `--c1`.
2. **Agent bug (seed 893, J10 "kept making job reports the store refused").** #159's
   `exited_unrecorded` reported a container that had ended with no start record under the
   epoch of the older observation (`seen.assignment`). Once the run was assigned again the
   store refused that report, and the agent made it again on every pass, about one per step
   on three nodes, for the whole run. `lost` already used the run's current assignment
   (`report_epoch`); `exited_unrecorded` now does too, and returns when the run has none.
   Evidence it is needed: with this change reverted on the merged head (ReleaseSafe), seed 893
   (`893 625 8 --lease-ttl-ms=10000 --replicas-pct=300 --heal-at=584`) fails J10 plain and
   under `--c1`; with it, both pass. A unit test in `src/agent_jobs_test.zig` ("a container
   that exited with no start record is reported under the current assignment") fails without
   it.

The `deadline_set` subtraction (#136, `de4fb07`) was written when a step's calls all saw the
time the step began. With #159's clock the node's clock includes the calls' time and the
remote compares the deadline with it, so the subtraction counted the time twice. Removing it
changed no seed that passed (the #136 replay passes either way). It is gone, and its unit
test now pins that the time counts once. Restoring it does not revive the tooth below
either, so it was not what blinded it. This does not touch a bound, limit or default: no
lease ttl bound, renewal fraction or code changed.

## The `job_deadline_offline` tooth

`sim-c1-teeth` failed on the first #171 head: the tooth ran seeds 1..10 and none failed J8.
Bisected on ReleaseSafe runners: #159's head fails J8 on one of the ten (seed 10); the merged
head none; restoring the `deadline_set` subtraction alone or reverting the first `arm_step` rule
alone changes nothing (with the restart rule instead, J8 fails on seeds 13, 26, 27, 30, 40); reverting the `exited_unrecorded` change makes 8 of 10 seeds fail,
but with J10, not J8, and J10 hides J8. So the fault is not blinded: with the agent fix, 11
of the first 80 seeds fail J8 (first at 13) and none fails anything else. Ten seeds were a
coin flip that any change of the draws could lose. The tooth now runs 1..40 (`seeds` in
`c1_teeth_roots`; it stops at the first failure).

Where: `src/sim_cluster.zig` (`Cluster.crash`, `Node.deadline_set`, `Node.step_once`),
`src/agent_jobs.zig` (`exited_unrecorded`), `src/agent_jobs_test.zig`, `build.zig`
(`c1_regressions`, `regress_replays` for `sim-c1-regress`, `c1_teeth_roots`).
