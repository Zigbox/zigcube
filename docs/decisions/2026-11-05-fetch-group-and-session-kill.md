# The swarm fetch has a process group of its own; a supervisor is killed by session

Status: decided 2026-11-05, on branch `claude/c2-fix-sched-deadline` (C2 release review, MUST 2
and its SHOULD).

## Problem

The supervisor's fetch deadline sent SIGTERM to the `zcube-agent fetch` pid and waited for it
without a bound. With a Zigbox store the real work is a grandchild (`zigbox.store.namespace.run`
makes it with `clone3(CLONE_NEWUSER)`, no `setsid`), which neither dies with the fetch nor hears
its signals; it survived, and `Real.pull` then started a second store writer beside it.

## Decision

- The fetch is spawned with `pgid = 0`. Whenever it ends (deadline or not) the supervisor, which
  is the group's subreaper for the while, sends SIGKILL to the group while the leader is still
  an unreaped zombie (so the group id names nothing else), and reaps until `kill(-pgid, 0)` says
  ESRCH, for at most `zigbox_fetch_kill_wait_ms`. If a process is left (state D), no pull starts:
  the start fails with ZC-E0515 and `fetch.log` says so.
- The brief's SHOULD said to signal `-pid` when the runtime kills a starting replica's supervisor.
  Once the fetch has a group of its own, `kill(-supervisor)` no longer reaches it. The supervisor
  leads its own session (`setsid` in `zigbox_supervisor.run`), so `kill_supervisor` kills the
  supervisor's group and then every process whose `/proc/<pid>/stat` session is the supervisor's
  pid (`process_session.kill_all`, a few rounds, bounded). Linux keeps a pid out of use while any
  process has it as its session id, and the launch lock proves the supervisor was alive, so the
  scan cannot reach a stranger's process.
- The kill is an `Options.kill_session` seam in `ZigboxRuntime`: the runtime's tests use a
  simulated host whose pids are not real, so they record instead of killing; one test runs the
  real kill on a real session.

## Rejected

- A `fetch.pgid` file the runtime would read: a race with the spawn and pid reuse after the
  supervisor dies.
- Keeping the fetch in the supervisor's group: the deadline's kill would then kill the supervisor.
