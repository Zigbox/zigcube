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

After #159 gave the simulated agent a per-call clock, seeds 1612 and 893 (and 1384 under
`--c1`) failed on code that passed on `main`. The first guess was the step-overrun class
(#169, #136): an agent step that runs past the fence. It was not. Two causes, neither of them
that class:

1. **Simulator artefact (seed 1612, I1b "self-fencing failed").** A `crash_now` that lands
   while a node is inside a step's spent time (`resume_ms > manual.ms`). The sim runs a step
   whole at its start, and the step's clock reading and saved lease pair already include the
   time its calls spent (10 s in 1612, a timed-out call). The agent that restarts reads a node
   clock held at that reading until true time catches up, and restores a lease stamped ahead
   of true time, so it fenced about 4 s late. A real agent that dies mid-step has written none
   of that and reads a clock that always moves. Fix in the sim: such a crash is armed for the
   step boundary (`arm_step`) instead of firing at once. The agent was right.
2. **Agent bug (seed 893, J10 "kept making job reports the store refused").** #159's
   `exited_unrecorded` reported a container that had ended with no start record under the
   epoch of the older observation (`seen.assignment`). Once the run was assigned again the
   store refused that report, and the agent made it again on every pass, about one per step
   on three nodes, for the whole run. `lost` already used the run's current assignment
   (`report_epoch`); `exited_unrecorded` now does too, and returns when the run has none.

The `deadline_set` subtraction (#136, `de4fb07`) was written when a step's calls all saw the
time the step began. With #159's clock the node's clock includes the calls' time and the
remote compares the deadline with it, so the subtraction counted the time twice. Removing it
changed no seed that passed (the #136 replay passes either way). It is gone, and its unit
test now pins that the time counts once. This does not touch a bound, limit or default: no
lease ttl bound, renewal fraction or code changed.

Where: `src/sim_cluster.zig` (`Cluster.crash`, `Node.deadline_set`), `src/agent_jobs.zig`
(`exited_unrecorded`), `build.zig` (`c1_regressions`).
