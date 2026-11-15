# sim-fencing-teeth runs seeds 2..4

*Decided 2026-11-13, by the slice (PR #244, fix of CI run 43449002710).*

`zig build sim-fencing-teeth` runs the simulator with the old `ttl / 3` renewal rule at a ttl of
4,000 ms; the first seed that fails must fail with `fencing_settles`'s symptom, "agents kept
fencing", or the step fails. After
fence waits became pauses (#225, ace4b59), seed 1 still fails, but with "a replica is not running
exactly once" at 353,861 ms in step `convergence`: the agent's place in its fence loop at the
moment of the check moved, and `converged` runs before `fencing_settles`.

That is the old rule's own failure seen first by another check, not a regression:

- With the two checks swapped in a scratch build, seed 1 fails with "agents kept fencing" at the
  same 353,861 ms.
- The same old-rule binary at ttl 8,000 ms, where `ttl / 3` renews before the fence, passes
  seeds 1, 2 and 3.
- Seeds 2 to 12 at ttl 4,000 ms fail with "agents kept fencing".
- The current rule cannot run at 4,000 ms (ZC-E0121); at the nearest admitted shape,
  `sim_cluster --seeds 1..50 100 1 --lease-ttl-ms=8000`, 0 of 50 fail.

The tooth moves to seeds 2..4 rather than accepting a second symptom: with
`--expect-symptom=agents kept fencing|a replica is not running exactly once` it could pass with
`fencing_settles` never firing, and proving that check bites is the tooth's purpose. The check
order is unchanged, so the fleet's fingerprints for other runs do not move.

Where: `build.zig` (`add_fencing_teeth_step`).
