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
fences and reports ZC-E0121. **Upgrade order:** raise the server's ttl to 9,000 ms or more (old
binaries accept it), let every agent renew under it, then upgrade. The demo's
`--lease-ttl-ms 8000` became 9000.

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

A lag within the bound is the margin's to absorb. A longer lag is caught at the first step that
runs, which is late by the stall itself; a stall longer than the margin is the wedged node of
authority.md §3. The model's other suggestion, a KILL timer that does not wait for a reconcile
step, was not part of (a) and is not built.

Where: docs/authority.md §2 and §3, docs/keys.md (`/node-tenure/<node>`), src/constants.zig,
src/fencing.zig, src/agent.zig (`kill_now`), src/node_controller.zig, src/replica_controller.zig,
src/controller.zig (`newer_tenure`), src/agent_api.zig (`register`), docs/demos/c1.md, and the
ttl of 9,000 ms in src/sim_shape.zig, src/server_config.zig, the demo-c1 sources, the E0121
text and testdata, and the regression lines in build.zig and src/sim_cluster_main.zig whose
ttls (8,516 and 8,799 ms) the new bound refuses.
