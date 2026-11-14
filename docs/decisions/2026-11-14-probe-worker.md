# The health check runs in a `zcube-agent probe` worker, and its timeout kills through a pidfd

*Decided 2026-11-14, by C3 slice 10; the supervisor settled its two open points (the internal
bound, and the pidfd in place of the Zigbox call the brief names) after the slice's review, and
the review's fixes changed how the worker's group is killed.*

**The worker.** `ZigboxRuntime.probe_begin` starts `zcube-agent probe <replica> <timeout_ms>
<command...>` and returns; `probe_poll` reaps it with `WNOHANG`. Zigbox's `exec_start` and
`exec_wait` block and must be the only thread of their process (Zigbox asserts it in debug
builds), so they cannot run in the agent, which is one thread that must not block. The worker
is the leader of a process group of its own, and the command it runs in the container stays in
that group (Zigbox's joiner forks it with CLONE_PARENT and no new session), with whatever the
command starts, unless it calls `setsid` or `setpgid`.

**The group dies at every end of a check, killed by the agent (fix of the slice's review).**
The worker's timer kills only the command, so a check like `sh -c 'sleep 3600 & true'`, or one
that times out with a child, would leave that child running, one per interval. The two ways to
kill the group were the worker's `kill(0, SIGKILL)` after it writes its line, or the agent's
`kill(-pid, SIGKILL)` when it sees the worker end. The agent does it: it needs nothing from the
worker, so a worker that crashed before its line is covered too, and it is the one place every
path (worker ended, check abandoned, worker past its grace) already goes through. `probe_poll`
asks with `waitid(P_PID, pid, WEXITED | WNOHANG | WNOWAIT)`, which leaves the ended worker a
zombie, so its pid, the group's id, cannot be reused before the kill; then it kills the group,
reaps the worker and reads its line. An abandoned check (a second check of the replica, `stop`,
a container gone, the table full, the worker past its grace, the agent's exit) gets the same
SIGKILL while the worker is unreaped, and its entry stays in the table, marked killed, until a
`WNOHANG` sweep at a later `probe_begin` or `probe_poll` reaps it. Nothing in the agent blocks on
a worker: when killed workers that do not die (stuck in the kernel) fill the table,
`probe_begin` is refused with ZC-E0502. The same sweeps end checks nobody polls any more (their
health check was removed): `worker_grace_ms` past its timeout, a check is collected if its
worker ended and abandoned if not. A full table of live checks drops a worker that ended, else
abandons the check begun first.

**The protocol** is one line on the worker's standard output: `exited N`, `timed_out`, or
`refused <diagnostic JSON>` (Zigbox's `diagnostic.write_json`, at most 16 KiB). The worker moves
that pipe to a descriptor above 2 with close-on-exec and points 0, 1 and 2 at `/dev/null` before
it calls Zigbox, so neither Zigbox nor the command can write into the result. Anything else (no
line, two lines, a bad line) is a refused check, ZC-E0502. The worker's exit code carries nothing.

**The timeout kills through a pidfd, not `exec_signal`.** The worker's second thread waits
`timeout_ms` and then sends SIGKILL to the command. Zigbox's `exec_signal` asserts the handle is
still `running` and reads `handle.pid.?`; `exec_wait`, in the other thread, sets `pid = null`
and the status `stopped` when the command ends, so a timeout that fires as the command ends
would race on the handle (an assertion failure, or a null unwrap). The worker opens a pidfd for
`handle.pid` after `exec_start` returns and before `exec_wait`, and the timer signals that
(`pidfd_send_signal`), which is safe whatever `exec_wait` has done. **This is a finding for
Zigbox, not a fix:** the brief says findings about `exec` go to the owner as Zigbox requests and
nothing is worked around. A thread-safe `exec_signal` (or an `exec_wait` with a deadline) would
let the worker drop its pidfd. Until the owner rules, the pidfd stays: the alternative,
`exec_signal` from the timer thread, is the race above. Brief question ZB-2: `exec_start` works
from a process other than the container's supervisor (it reads the run's record from Zigbox's
state directory); when the container ends first, `exec_wait` returns `signaled 9` with the
container gone, which the worker reports as refused ("the container ended while the check ran").
Both are read from Zigbox v0.5.0's source and its tests, not seen on a host (see below).

**`worker_grace_ms` = 5,000** (internal, `src/zigbox_probes.zig`): a worker still running that
long after its check's `timeout_ms` is killed with its group and the check refused (ZC-E0502).
It covers a Zigbox call that hangs before the command runs, which the worker's own timer does
not bound (the timer starts when `exec_start` returns). **Settled by the supervisor after the
review: internal and provisional.** No key, flag or record names it.

**Settled by the supervisor after the review: the pidfd timeout kill is accepted for now.** A
Zigbox request goes to the owner for a thread-safe `exec_signal`, or an `exec_wait` with a
deadline; with either, the worker drops its pidfd and its timer thread.

**Not run here.** The cloud container has cgroup v1 and no `newuidmap`, so `zbx` cannot run a
container (`zbx doctor`: ZBX-E0103, ZBX-E0105), and it has no KVM for `zigbox-smoke`. The worker
is covered by unit tests (its line format and arguments, its verdict, its streams), by
`zigbox_probes.zig`'s tests against a fake worker script that leaves a child (the group kill on
each path, eviction, the sweep, a table full of killed workers), and by a test that runs the
built `zcube-agent probe` on a container that does not exist and reads one line, ZBX-E0402.
The `health` stage of `zigbox-smoke` is the first real run; it now also counts the background
children of a check that times out and of one that passes.

Where: `docs/agent.md` ("Health checks"), `src/probe_worker.zig`, `src/zigbox_probes.zig`,
`ops/zigbox-smoke/guest.sh` (`stage_health`).
