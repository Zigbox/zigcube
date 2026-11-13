# #238: a grace per tenure, and two more terms in the fencing inequality

*Decided 2026-11-13: the owner chose the repairs, and the implementing slice chose their numbers
and mechanism (flagged below for the supervisor).*

The TLA+ model of fencing (`Zigbox/zigcube-tla`, branch `claude/fencing-model`, `FINDINGS.md`)
found three holes in authority.md §3. The owner chose option (a) for each:

- **Finding 2, the lost grace counts from each expiry.** A node that is lost, registers again and
  loses the new tenure before the node controller has judged it was treated as lost under the
  old verdict, whose grace was long over, so its replicas could be replaced with no grace at all.
- **Finding 3, forward steps of the store clock.** Lease deadlines are absolute values on the
  store's clock, so a forward step ends every lease early. authority.md now states a bound on
  such a step as an assumption, beside the rate-skew bound, and the inequality includes it.
- **Finding 4, a late agent step.** The step that sends KILL can run late, and nothing bounded
  how late. The inequality gets a step-lag term, and the agent measures its own lag and stops
  waiting when it is past the bound.

## The numbers: 500 + 500, and the margin from 3,000 to 4,000 ms

The owner allowed 1,000 ms in all for the two new terms. The slice split it evenly:

- **`agent_step_lag_max_ms` = 500.** A healthy agent wakes within `fence_poll_ms` (100) of when
  it is due. 500 leaves room for a slow listing or a scheduler hiccup under load, and it is half
  of `agent_resync_ms`. A host that stalls its agent for longer is a wedged node, for which no
  margin can promise anything (authority.md §3).
- **`store_clock_step_max_ms` = 500.** By default chronyd's `makestep` and ntpd step the clock
  only past about 500 ms of error and slew below it, so 500 is the bound a store host gets
  without special configuration. A host set to step wider, or a manual `date -s`, breaks the
  assumption. Nothing checks it, and authority.md says so.

`fence_margin_ms` goes from 3,000 to 4,000 ms: 2,000 stop + 100 skew at 10 s + 900 kill latency
+ 500 + 500. As before, the default ttl of 10 s uses the margin exactly, so **the default ttl is
also the longest one admitted**.

**Failover: the brief expected about 1 s more; here it is the fence that moves.** The server's
expiry and grace do not change, so the time from a power-off to a replacement is still
`ttl + lost_grace_ms`. What moves is the cut-off node: it stops its containers `ttl − 4 s` after
its last acknowledged keepalive, not `ttl − 3 s`, so a partition costs its replicas one more
second of unavailability before the replacements start. Restoring the old margin of safety by
lengthening the ttl instead would cost the whole second on every failover.

## The shortest ttl moves from 8,000 to 9,000 ms (flagged)

The shortest ttl is `fence_margin_ms + fence_window_min_ms`. With the window kept at 5,000 ms,
it becomes **9,000 ms**. This was not chosen silently; the supervisor may prefer the
alternative:

- **Kept here: the window at 5,000, the shortest ttl 9,000.** The renewal falls at `ttl / 3`,
  3,000 ms at 9 s, and leaves 2,000 ms before the fence (was 2,334). The simulator's drawn range
  becomes 9,000 to 10,000 ms (`sim_shape.lease_ttl_ms_min`).
- **The alternative: cut the window to 4,000 and keep 8,000.** At 8 s the renewal falls at
  2,666 ms and leaves 1,334 ms of slack, still above `renew_slack_min_ms` (1,000). It works, but
  it narrows the renewal room that #78 was about. That is a user-visible bound, so it is the
  supervisor's call.

Either way, the change is user-visible. A server configured with `--lease-ttl-ms` between 8,000
and 8,999 is refused at start with ZC-E0121, and an agent granted such a ttl by an older server
fences and reports ZC-E0121. The demo's `--lease-ttl-ms 8000` became 9000. The supervisor kept
the 9,000 ms floor (`2026-11-13-ttl-floor-9000.md`, which supersedes the 8,000 ms floor of
`2026-11-06-renewal-before-fence.md`).

**Upgrade order:**

1. Raise any ttl below 9,000 ms to 9,000 or more. Old binaries accept it; let every agent renew
   under it.
2. Upgrade the server. From here every registration writes `/node-tenure/<node>`, old agents'
   included, so finding 2 is closed for the whole cluster.
3. Upgrade the agents. Until a node's agent is upgraded it fences at `ttl - 3 s` without the
   step-lag check, so findings 3 and 4 stay open on that node: the new inequality, with its
   step-lag and clock-step terms, holds only for upgraded agents.

## Finding 2: a `/node-tenure/<node>` key (a new key, flagged)

The node controller could not tell a newer, unjudged tenure from the one it had judged. A
tenure can register and expire between two of its passes, and its `/nodes` key goes with the
lease. So the registration's transaction (`PUT /v1/agent/nodes/<node>`) now also writes
`/node-tenure/<node>`. The key is not bound to the lease, and it is written at the same revision
as `/nodes/<node>`.

- The node controller writes `lost` for a tenure newer than the judged one, stamped at the pass
  that sees it, so `lost_grace_ms` counts from there. It keeps that node's observed records
  until then.
- The replica controller does not replace a node's replicas while a newer tenure is unjudged.
- A placement that relies on `/nodes/<node>` being absent compares `/node-tenure/<node>` at the
  revision it read. Otherwise a registration between the read and the commit could slip past.
  This is still one compare per node, so the budget of `store_txn_compares_max` is unchanged.

The job controller needed no change: when the status names another tenure, it already counts a
run's tenure end from its own first sight of it.

The new key is owned by the agent, through the registration, and `writers.zig` and keys.md list
it. A node registered before this change has no such key. It behaves as before until its next
registration writes one.

The other options were rejected:

- Watching the `/nodes/` delete events still misses a key the controller never saw.
- Gating assignments on the server does not do what the owner chose.

## Finding 4: what "late" means

The agent compares each step's start with the fence time it computed, or, while fencing, with
the kill time. Lag against any other wake does not count. A slow watch or a long call is not
dangerous unless it makes the agent late for the fence.

- If a step starts more than `agent_step_lag_max_ms` past the fence time, it fences and kills in
  that same step. It does not wait for the nominal kill at `fence + stop`.
- If a fencing step starts more than the bound past the kill time, it also kills at once. That
  step would anyway, so here the rule only counts it.
- Each such step adds one to `Agent.lag_kills`. Later polls of a fence that has already sent
  KILL are not late for anything and are not counted.

A lag within the bound is the margin's to absorb. A longer lag is only detected: only lag on the
KILL step adds overlap, and a KILL step that begins late has already spent its lag, so the bound
is an assumption about the host, like the clock-step bound, which the agent cannot enforce. The
shell logs each lag kill with the lag against the bound, and the cluster simulation reports
`lag_kills=` beside `fences:`; a stall longer than the margin is the wedged node of
authority.md §3. The model's other suggestion, a KILL timer that does not wait for a reconcile
step, was not part of (a) and is not built.

## Two pinned regressions that no longer replay their worlds

Two pinned runs had ttls the new floor refuses, and now replay at 9,000 ms: the busy-loop test
of `sim_cluster_main.zig` (8,516 ms) and fleet issue 136's test and `c1_regressions` line
(8,799 ms). At 9,000 ms with the 4 s margin these are other worlds, so they pass without showing
that the old bugs stay fixed. Re-proving each against its reverted fix, or shrinking new seeds
at an admitted ttl, was not done in #238's review pass (it needs each original fix reverted and
a fresh shrink, more than the review asked of this branch). What guards them instead:

- issue 136: `sim_cluster.zig`'s test "a step's calls are capped by the time it has spent,
  once", which does not depend on a seed;
- the busy-loop stop: no test independent of the seed. It is left to the work ceiling
  (`work_under_ceiling`, `steps_per_minute_max`) that every cluster simulation run checks, and
  a follow-up should pin a new seed.

## Two teeth whose worlds moved

The registration now writes one more key, and the fence falls 1 s earlier. Together these shift
every simulated world, so two of `sim-c1-teeth`'s pinned seeds moved. The checks did not change.

- **`job_stale`.** With the fault on, a run fails J9 (a stale report stored) or J10 at rest (the
  tooth's plain symptom) first. Seed 1 was a J9 world, and now it fails J10. Over seeds 1 to 80,
  J9 shows first on 26 seeds on the base commit and on 28 here, and no seed passes on either. The
  tooth bites as before. Its run now sets `any_symptom`, as the skew tooth does: seeds that fail
  otherwise are skipped, and J9 must still show on some seed in 1..10 (seed 5 here).
- **`job_evicted`.** This sparse tooth no longer fires at seed 186
  (`2026-11-11-job-evicted-tooth-sparse.md`). On this branch, seeds 1 to 47 pass with the fault
  on, and seed 48 is the first hit ("J8: a run that no node started..."). With the fault off
  (`sim_c1_evict_world_main`), seed 48 passes. The supervisor asked this branch **not** to
  re-pin it: the fleet-blockers branch (#225) moves the same tooth and lands first, and the
  supervisor reconciles the seed after both land. So `build.zig` still names 186, and
  `sim-c1-teeth` fails at `job_evicted` alone on this branch.

Where: docs/authority.md §2 and §3, docs/keys.md (`/node-tenure/<node>`), src/constants.zig,
src/fencing.zig, src/agent.zig (`kill_now`), src/node_controller.zig, src/replica_controller.zig,
src/controller.zig (`newer_tenure`), src/agent_api.zig (`register`), docs/demos/c1.md, and the
ttl of 9,000 ms in src/sim_shape.zig, src/server_config.zig, the demo-c1 sources, the E0121
text and testdata, and the regression lines in build.zig and src/sim_cluster_main.zig whose
ttls (8,516 and 8,799 ms) the new bound refuses, and the `job_stale` tooth's run (above).
