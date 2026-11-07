# A lease is renewed before its fence, and the shortest ttl is 8,000 ms

*Decided 2026-11-06, by the implementer of #78; revised after the reviews of PR #124; the
8,000 ms bound is the owner's, 2026-11-06.*

Where: `src/fencing.zig` (`renew_after_ms`, `inequality_problem`, `raise_problem`),
`src/constants.zig` (`fence_window_min_ms`, `renew_slack_min_ms`), `src/agent.zig`
(`acknowledged`, `restore`), `src/sim_cluster.zig` (`fencing_settles`), `src/sim_shape.zig`,
`docs/agent.md`, `docs/core.md`, `docs/briefs/c3.md`.

**Supersedes** the *condition* of `2026-11-05-fleet-ttl-floor.md` ("until #78 is fixed"): #78 is
fixed here, and the floor of 8,000 ms it set is now the bound itself, so nothing waits for
another issue. The rest of that file stands.

**Root cause.** The agent renewed its lease `ttl / 3` after sending the last keepalive but
fences at `ttl - fence_margin` (3,000 ms). For `ttl <= 4,500` the renewal falls at or after the
fence, so a healthy agent fenced before every renewal and registered again, once a second for
ever. `fencing.zig` only required `ttl > margin`.

**Fix.** `fencing.renew_after_ms(ttl)` is `min(ttl / 3, window - 1000)`, with `window = ttl -
margin`: a third of the ttl, but never later than 1,000 ms (`renew_slack_min_ms`) before the
fence. At the admitted ttls (8,000 and up) the minimum never binds, so the rule is `ttl / 3`
and the slack before the fence is 2,334 ms at 8,000 and grows with the ttl; the minimum stays so
that a smaller bound cannot bring #78 back. A unit test checks every ttl from 8,000 to 20,000:
the slack is at least 1,000 ms and never decreases. The shipped 10 s is unchanged (renewal at
3,333 ms).

**The bound.** `fence_window_min_ms` is 5,000, so the shortest admitted ttl is 8,000 ms
(`fence_margin_ms` 3,000 plus 5,000) and `ZC-E0121` (`ttl_too_short`) refuses every ttl below. The
owner chose 8,000 ms for the bound and the simulator's draw alike (2026-11-06): the admitted and
the drawn ranges are the same, which closes the gap that issue #125 describes (a ttl the server
accepts at 5,000 to 8,000 ms but the fleet never draws, because seeds 254 and 343 fail the
busy-loop check there). Those seeds are no longer reachable through the server; #125 itself stays
open until the supervisor closes it. Earlier rounds of this PR found that 3,500 ms admitted ttls
the simulator calls a busy loop (30 of 60 seeds), and that 5,000 ms was still inside the failing
range. `ZC-E0121`'s explanation says which way to move: lengthen a ttl below 8,000 ms, shorten
one the margin cannot cover.

**Upgrade.** Raise the ttl before upgrading anything. On the old server set `--lease-ttl-ms` to
8,000 or more (or leave the default of 10,000) and let every agent renew under it, then upgrade.
An upgraded server started with a ttl below 8,000 is refused with `ZC-E0121`. An agent upgraded
while the ttl is below 8,000 fences its node: `Agent.restore` finds a lease file with such a ttl
unusable and stops every container on restart, and `Agent.acknowledged` refuses a granted ttl
below the bound with `ZC-E0121`, fences, and fails the step (it does not assert on a value from
the network, and it does not crash-loop; it repeats the refusal on each registration, so the
node runs nothing and says why). Upgrade the server's ttl first, agents second.

**Check.** `sim_cluster` fails a healed run in which a node fences more than 4 times after the
heal (`fencing_settles`). It runs after the heal, where the links have no latency, so it catches
a renewal that falls after the fence and not one with too little slack for the round trip; the
slack is covered by the unit test. Teeth: `zig build sim-fencing-teeth` runs the simulator with
the old `ttl / 3` rule and the ttl bound lifted (`c1_teeth_old_renewal_rule`, test-only), at 4,000
ms, and must fail with "agents kept fencing". It stays at 4,000, below the bound, on purpose: at
no ttl the server admits can the old rule fail the check with zero latency (at 8,000 ms the
renewal comes at 2,666 ms and the fence at 5,000 ms, in time), so a test inside the admitted range
could not fail. It is not a `c1_teeth_roots` entry: the fleet's canary draws no ttl by hand. It
runs in CI next to `sim-c1-teeth`. No latency was added to the healed links, which would change
every seed's world.

**Fleet.** The draw floor stays at 8,000 ms (`sim_shape.lease_ttl_ms_min`), which is now also
the bound. A ttl given by hand (`--lease-ttl-ms=N`) must pass the same check as the server's.
