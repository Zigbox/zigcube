# J6 has no bound while the runs read fails and keepalives succeed (pending the owner)

*Recorded 2026-11-14, by the fix slice of #142 (claude/b3-j6-142). **Pending the owner's
choice**: nothing here is decided, and no code implements either option.*

## The gap

J6 bounds how long a run keeps executing after its stop commits. The bound rests on two ways
the agent stops a run: it reads the stop from `/job-runs` (via `GET .../runs`), or its lease
renewals stop and the fence stops everything. Each step's keepalive comes before the reads.

A store (or server) that answers the keepalive and fails the runs read on every step defeats
both: the agent never sees the stop, and the lease never lapses, so the fence never comes. The
run executes until its own deadline (enforced locally, `enforce_deadlines`), however far past
J6's bound that is. After the #142 fix every other failing call of a step still lets the pass
read the runs and stop; this one read is the one the agent cannot work around, because it is
where the stop is.

No fleet seed has shown it. The tooth `sim-c1-teeth-job_runs_unread` (`c1_teeth.zig`,
`agent_api.zig` `runs`) shows it: the server fails a node's runs read whenever one of its runs
has a stop asked, and answers everything else. sim-c1 catches it as J6 at seed 2 (and 4 and 7,
pinned as the canary's; 11 of seeds 1 to 40 at 100 operations fail J6 first). The tooth is an
expected failure: it passes only while J6 fires. Once an option lands, J6 must hold in its
world, and the tooth becomes a positive run (as `sim-c1-offline` is for `job_deadline_offline`).

## The options

A. **Renew only after a step whose runs read succeeded.** The keepalive moves after the runs
   read, or is withheld when the last runs read failed. The existing fence then bounds J6 by
   the fence term, with no new mechanism. Cost: a node whose runs read fails loses its lease
   and fences its replicas too, not only its runs, and the read becomes part of liveness
   (a server bug in `/runs` takes nodes down).

B. **A local job fence from the last good runs read** (reviewer B's recommendation). The agent
   keeps the monotonic time of its last successful runs read. Past the J6 fence term from it,
   it stops its running job containers with cause `unreachable` (the cause a run the server no
   longer serves gets), without touching the lease or the replicas. Cost: a new timer in the
   agent and in `next_wake`; a job on a node with a flaky `/runs` is stopped while its
   replicas run on, and its report waits for the server.

Either changes the agent's stopping behaviour under a fault, so the choice is the owner's
(AGENTS.md: a user-visible bound or behaviour).

Where: `src/c1_teeth.zig` (`job_runs_unread`), `src/agent_api.zig` (`runs`),
`src/sim_c1_teeth_job_runs_unread_main.zig`, `build.zig` (`c1_teeth_roots`),
docs/decisions/2026-11-14-j6-reports-read-keeps-stops.md.
