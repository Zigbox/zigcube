# peers_fetch passes as `cube`: the cause was the single-threaded Io's allocator

Status: decided 2026-11-05, C2 slice 9. Supersedes
`2026-11-04-c2-slice8-m4-smoke-blocked-on-z9.md` (and its "Update" section) and the "agents run as
root" reasoning in it. Those files stay as written.

## What the evidence says

CI run 41955830319 (the push of slice 8's merge, `bffa955`, to main), zigbox-smoke, agents as
`cube`: stage `peers_fetch` passed. B fetched python:3.12-slim entirely from peer A, 115,409,299
peer bytes, 0 registry bytes.

The empty `fetch.log` and `peer=0` of run 41888110848 were not the Z9 gap. The supervisor runs on
a single-threaded `std.Io.Threaded` (Zigbox's namespaces need a one-thread process), and that Io's
static allocator is a failing one. Spawning the swarm fetch copies argv and the environment, so
the spawn ended in OutOfMemory before the fetch started; the supervisor then pulled everything from
the registry. The fix is in `zigbox_supervisor.zig` (`run` gives the Io the process's allocator and
environment) and the spawn failure now leaves a line in `fetch.log` ("could not start the fetch").

## Consequences

- Gaps 1 and 2 (`docs/swarm.md`, review-fixes M3) did not cause that failure. They are Zigbox
  facts that held in the unit test and are not shown to be closed or open by the smoke: the
  smoke's python image passed as a non-root agent, so whatever files it has did not hit them. They
  stay reported to Zigbox, and `docs/swarm.md` says so.
- Agents stay `cube`; root stays out (`2026-11-05-zigbox-smoke-agents-not-root.md`).
- Lesson: an empty `fetch.log` is a defect of the reporter. The supervisor now writes a line for
  a fetch that did not start, that failed, or that the deadline killed.
