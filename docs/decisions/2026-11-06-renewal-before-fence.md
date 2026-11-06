# A lease is renewed before its fence, and the shortest ttl leaves room to do it

*Decided 2026-11-06, by the implementer of #78; revised after the review of PR #124. Pending the
owner's confirmation.*

**Root cause.** The agent renewed its lease `ttl / 3` after sending the last keepalive but
fences at `ttl - fence_margin` (3,000 ms). For `ttl <= 4,500` the renewal falls at or after the
fence, so a healthy agent fenced before every renewal and registered again, once a second for
ever. `fencing.zig` only required `ttl > margin`.

**Fix.** `fencing.renew_after_ms(ttl)` is `min(ttl / 3, window - 1000)`, with `window = ttl -
margin`: a third of the ttl, but never later than 1,000 ms (`renew_slack_min_ms`) before the
fence. The slack before the fence, `window - renew_after_ms`, is 1,000 ms at 5,000 ms and never
shrinks as the ttl grows (a unit test checks every ttl from 5,000 to 20,000). The rule differs
from `ttl / 3` below 6,000 ms only; the shipped 10 s is unchanged. (A first version kept `ttl / 3`
from 5,000 up, which left 334 ms at 5,000 and 1,000 ms at 4,999: raising the ttl made a healthy
agent likelier to fence.)

**The bound.** `fence_window_min_ms` is 2,000, so the shortest admitted ttl is 5,000 ms and
`ZC-E0121` (`ttl_too_short`) refuses anything below. At 3,500 the bound admitted ttls that the
simulator calls a busy loop (30 of 60 seeds at 3,500) and the agent renewed 250 ms after the
last send, so one slow pass fenced a healthy node. `sim_cluster --seeds 1..60 100 3
--lease-ttl-ms=5000` passes.

**Upgrade.** Change the ttl first, then upgrade: a server started with `--lease-ttl-ms` from
3,001 to 4,999 is refused with `ZC-E0121` (before this change it ran, and refenced once a
second). Set it to 5,000 or more, or leave the default of 10,000.

**Check.** `sim_cluster` fails a healed run in which a node fences more than 4 times after the
heal (`fencing_settles`). It runs after the heal, where the links have no latency, so it catches
a renewal that falls after the fence and not one with too little slack for the round trip; the
slack is covered by the unit test. Teeth: `zig build sim-fencing-teeth` runs the simulator with
the old `ttl / 3` rule and the ttl bound lifted (`c1_teeth_old_renewal_rule`, test-only), at 4,000
ms, and must fail with "agents kept fencing". At no ttl the server now admits can the old rule
fail the check with zero latency (5,000 ms: renewal at 1,666 ms, fence at 2,000 ms, in time), so
the test runs below the bound. It is not a `c1_teeth_roots` entry: the fleet's canary draws no
ttl by hand. No latency was added to the healed links, which would change every seed's world.

**Fleet.** The draw floor stays at 8,000 ms (`sim_shape.lease_ttl_ms_min`, as
`2026-11-05-fleet-ttl-floor.md`). 5,000 to 8,000 ms is admitted but not drawn: seeds 254 (ttl
5,181) and 343 (5,129) fail the busy-loop check under `crash_heavy` at 5,000 to 6,000 ms with and
without this fix, and that is tracked in issue #125, not fixed here. By-hand replays cover that
range until #125 is resolved; then the floor drops, with a decision file of its own.
