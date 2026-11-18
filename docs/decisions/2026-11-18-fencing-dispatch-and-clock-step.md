# The fencing contract covers a late kill and a forward step of the store's clock (option B)

*Decided 2026-11-18, by the supervisor (option B: the grace enters the inequality; the ttl floor
and every default stay). Implemented by the fencing-contract slice.*

## The gap

At the default ttl the old inequality was exactly spent:

    fence_margin_ms  >=  fence_stop_ms + skew(ttl) + fence_kill_latency_ms
    3000             >=  2000          + 100       + 900                     (0 ms to spare)

with `skew(ttl) = ceil(ttl × clock_skew_per_mille / 1000)`. Two delays had no term:

- **Late dispatch of SIGKILL.** A fencing agent looks at its containers every `fence_poll_ms`
  (100 ms), so the kill can leave up to one poll after `fence + fence_stop_ms`. Jepsen measured a
  5.395 s overlap from dispatch latency (zigcube-jepsen
  `docs/findings/2026-11-14-late-fence-kill-f7736a7.md`); the wait behind that was fixed, the
  poll's own delay was never counted.
- **A forward step of the store's clock.** Lease deadlines are absolute times on the store's clock
  (Postgres `clock_timestamp()`, or the server host's wall clock for SQLite). A forward step of
  `d` ms ends every lease `d` ms early, while the agent fences on its own `CLOCK_BOOTTIME`. The
  TLA+ model found it (#238, finding 3); PR #242 proposed a term for it.

## The rule

Two conditions, both checked by `src/fencing.zig`:

1. **The agent's condition**, unchanged: `fence_margin_ms >= fence_stop_ms + skew(ttl) +
   fence_kill_latency_ms`, and `ttl >= fence_margin_ms + fence_window_min_ms`. An agent checks a
   granted ttl against it (`inequality_problem`); a grant carries no grace, so this is all an agent
   can judge. The longest admitted ttl stays 10,000 ms and the shortest 8,000 ms.
2. **The contract**, new: the margin and the lost grace together cover every delay between the
   agent's last keepalive and the old container's death, in the server's terms:

       fence_margin_ms + lost_grace_ms  >=  fence_stop_ms + skew(ttl) + fence_kill_latency_ms
                                              + kill_dispatch_ms + clock_step_max_ms
       3000 + 1000                      >=  2000 + 100 + 900 + 100 + 500  =  3600

   400 ms to spare at the default ttl and grace. The server checks it at start
   (`contract_problem`, in `server_config.zig`) against its own `--lost-grace-ms`, and refuses a
   failing pair with **ZC-E0121**, its cause naming the grace, the shortest grace and the total
   the terms need. No new code.

New declared constants (`src/constants.zig`):

- `kill_dispatch_ms = fence_poll_ms` (100 ms).
- `clock_step_max_ms = 500`: an **operator requirement**, documented in `docs/operations.md`,
  "Clocks": the database host's clock slews and never steps after boot (chrony `makestep 1.0 3`,
  no manual `date -s`). Zigcube cannot observe a step.

The grace's lower bound, `grace_min_ms(ttl) = cover_needed(ttl) − fence_margin_ms`:

| ttl (ms) | skew | needed | shortest grace |
|---------:|-----:|-------:|---------------:|
|    8,000 |   80 |  3,580 |            580 |
|   10,000 |  100 |  3,600 |            600 |

So `--lost-grace-ms` under 580–600 ms (by ttl) is now refused; the default, 1,000, is admitted
at every admitted ttl.

## Upgrading

Only the server changes. A server started with `--lost-grace-ms` (or `.lost_grace_ms`) below the
shortest grace for its ttl, 580 to 600 ms, no longer starts (ZC-E0121, naming the grace): lengthen
it before upgrading, or drop the flag for the default. Agents are unchanged and check grants as
before, so servers and agents upgrade in either order.

## Why the grace and not the floor

The alternative (PR #242) raised `fence_margin_ms` to 4,000 and with it the shortest ttl to
9,000 ms, which refuses servers configured at 8,000–8,999 and fences agents granted such a ttl by
an older server. The owner's floor is 8,000 ms. The grace is server-side only, already waited for
by the node controller after expiry, and the default (1,000 ms) already holds the 600 ms the new
terms need: nothing a running cluster does changes. Failover takes no longer.

Why the server's check keeps condition 1 rather than only the sum: the sum alone admits ttls up to
50,000 ms at the default grace (and more with a longer one), which moves the longest admitted ttl;
the ruling kept every bound but the grace's. The agent's half also keeps the agent's promise
independent of a grace it cannot see.

## What PR #242 had that this does not take

- **The margin of 4,000 and the floor of 9,000**: replaced by this rule.
- **`agent_step_lag_max_ms` and the lag kill**: the dispatch term here is the poll alone. A step
  later than one poll (a stalled or descheduled agent) is the "wedged" case of authority.md §3,
  outside the bound as before; the lag kill does not bound it either (#242's review).
- **The per-tenure grace (`/node-tenure/<node>`, finding 2)**: a separate fix of the node
  controller with a new key and a review MUST open (no test fails without its replica-side
  gates). It is not needed for this arithmetic and is left for its own slice; until then a node
  lost twice before the controller judges it can still lose its grace (#238).

## The Jepsen checker reads the bounds from the tarball

The checker hard-coded I1b's window (1,900 ms in zigcube-jepsen's `stale_put.clj`) and parsed
`src/constants.zig` from a checkout named by a flag (`lease_checkers.clj`), which can differ from
the binaries deployed, and whose regex cannot read `kill_dispatch_ms = fence_poll_ms`. Now
`zig build dist` writes `share/jepsen/fencing-bounds.edn` from `src/constants.zig` (imported by
`build.zig`, `fencing_bounds_edn`) in the same build as the executables beside it: the tarball the
battery deploys carries the bounds of exactly those binaries, and the checker computes every
bound from them (docs/jepsen.md, "The declared bounds"). Chosen over a `zcube-server` option that
prints them because it needs no binary run on the control host, and over a checked-in copy
because a copy can drift.

## The tooth

`sim-c1-teeth-store_step` (`src/sim_c1_teeth_store_step_main.zig`, `c1_teeth.store_clock_step`):
while faults run, the simulated store's clock steps forward by more than `clock_step_max_ms`
(by 501 ms plus a quarter to a half of the ttl, about every 5 s of simulated time, from a PRNG of
its own, so worlds without the tooth draw as before), and sim-c1 must fail I1b. A step only
matters when it lands while a cut-off node's lease runs out, and one inside the simulated kill's
slack breaks nothing, hence the size. Catch rate, `sim_c1_teeth_store_step <seed> 100 --c1`:
**9 of seeds 1..30** (4 5 10 14 15 17 19 26 29), every one I1b ("a container runs on a node whose
lease ran out longer ago than the lost grace"); the other 21 pass. Stepping after the heal too
made every other seed fail the liveness check instead, so the tooth stops at the heal.
`sim-c1-teeth-store_step` catches it at seed 4 of 1..10; its canary runs seeds 1..30.

Where: `src/fencing.zig`, `src/constants.zig`, `src/server_config.zig`, docs/authority.md §3,
docs/operations.md "Clocks", docs/core.md "sim-c1".
