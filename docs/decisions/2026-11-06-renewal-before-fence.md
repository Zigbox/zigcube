# A lease is renewed before its fence, and the shortest ttl leaves room to do it

*Decided 2026-11-06, by the implementer of #78. Pending the owner's confirmation.*

**Root cause.** The agent renewed its lease `ttl / 3` after sending the last keepalive but
fences at `ttl - fence_margin` (3,000 ms). For `ttl <= 4,500` the renewal falls at or after the
fence, so a healthy agent fenced before every renewal and registered again, once a second for
ever. `fencing.zig` only required `ttl > margin`.

**Fix.** `fencing.renew_after_ms(ttl)` is `min(ttl / 3, (ttl - margin) / 2)`: unchanged for
ttls above 6,000 ms (the shipped 10 s included), half the time before the fence below that.
The shortest admitted ttl is now `margin + fence_window_min_ms` (500) = 3,500 ms; below it a
renewal does not fit (`--lease-ttl-ms=3001` still never settled, 3,200 doubled the agent's
steps), and `ZC-E0121` refuses it as `ttl_too_short`. No new code.

**Check.** `sim_cluster` fails a healed run in which a node fences more than 4 times after the
heal (`fencing_settles`). The unit test in `fencing.zig` fails with the old `ttl / 3`. No
`sim-c1-teeth` root was added: it needs a seventh root, canary and fleet entries.

**Fleet.** The draw floor drops from 8,000 to 3,500 ms (`sim_shape.lease_ttl_ms_min`), which
changes which world a seed means for `auto` runs. Supersedes `2026-11-05-fleet-ttl-floor.md`.
