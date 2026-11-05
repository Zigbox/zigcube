# The fleet's lease ttl floor is 8,000 ms until #78 is fixed

*Decided 2026-11-05, by the supervisor.*

The shape draw (`sim_shape.draw_shape`, `<ops>` = `auto`) draws the lease ttl uniformly from
8,000 to 10,000 ms (the shipped 10 s 40 % of the time), not from 5,000 ms as
`2026-11-04-fleet-profiles-and-shapes.md` said. That record's floor was set from a one-node run;
the 2,000-seed sweep it also records found the same failure at ttls up to 6,172 ms, and a replay
of seed 86 (`crash_heavy`, ttl 5,959) fails at `end` with a busy-loop verdict. That is issue #78's
known symptom (a short lease ttl makes a healed cluster fence again and again). A fleet that
draws ttls in that range would file it again and again under new fingerprints.

So until #78 is fixed the draw's floor is 8,000 ms. A ttl given by hand
(`--lease-ttl-ms=N`) is still accepted at any value in range, so a replay of the known failure
still works. In that sweep seed 254 holds at 8,000 and fails at 6,000, and seed 343 fails at 7,000.

**When #78 closes** the floor drops back (to 5,000 or lower, as the fix allows) in
`sim_shape.lease_ttl_ms_min`, in `docs/core.md`, and a new decision file says so. Drawing
different ttls from the same seed changes which world a seed means, so the change lands with a
note in that file.

Where: `src/sim_shape.zig` (`lease_ttl_ms_min`), `docs/core.md` ("Profiles and shapes").
