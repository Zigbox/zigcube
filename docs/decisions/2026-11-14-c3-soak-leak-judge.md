# The soak's leak judge, its memory budget and its exits

*Decided 2026-11-14 by the supervisor, on the two reviews of C3 slice 4 (both found that the
ratio judge of `docs/decisions/2026-11-14-c3-soak-and-replay-artefacts.md` passes a leak that is
linear from the first operation: a 64 KB/op and a 200 KB/op mutant held). Implemented by the
slice's fix session. It changes a default only inside the fleet's tooling.*

**Rulings.**

1. *Leak judge.* After the run and the world's teardown, the soak's counting allocator must hold
   nothing: on every stop (operations done, the minutes budget, the bytes budget) a live count
   above 0 fails the soak with `soak: memory still held after the world was torn down` and the
   bytes. The ratio judge stays, and a slope judge joins it. A test-only per-operation leak
   tooth must fail.
2. *Memory.* A deterministic live-bytes budget ends the soak, as held, with `budget reached`
   (default 1.5 GiB, `--soak-bytes=B`); `sim-soak.service` keeps `MemoryMax=2G`. In `soak.sh`
   exit 137 (signal 9) is the host's, as in `run.sh`, and exit 2 (the runner refused its
   environment or arguments) is logged and not ingested; neither files a crash.
3. *Stderr.* A soak that wrote to stderr says so in its verdict: `soak: stderr not empty:` and
   the first line, which the reporter carries in the issue's trace block.

**The teardown check catches what the ratio cannot.** Every byte the world takes is freed by
`Cluster.destroy`; whatever is still live after it was never freed, whatever its rate. It
catches the tooth (16 KiB per operation: 9,830,400 bytes after 600 operations of seed 7), Review
A's 64 KB/op mutant and Review B's 200 KB/op mutant, at any length of run. It does not catch
memory held on purpose and freed at the end (a cache that only grows); the slope judge is for
that.

**The slope judge: cumulative, not per epoch (a deviation from the ruling's letter).** The ruling
asked for per-epoch byte growth over per-epoch item growth, compared with the first post-warm-up
epoch. Measured on a healthy soak (seed 7, 4,000 operations, epochs of 250, ReleaseSafe), live
bytes move in steps as arrays double (18.5 MB, 32, 42, 70.7, 100.4, 102.6, 116.7, 131.8, 134.7,
136.3, 137.5, 138.8, 173.2, 176.3, 208.2, 209.8 MB at epoch 16), so the per-epoch slope ran from
0 to about 6,000 bytes per item: any factor that passes that fails nothing. The judge instead
takes the slope since the warm-up (the fourth epoch): bytes added since then over items added
since then. Its baseline is the larger of that slope at the first epoch after the warm-up and
the warm-up's own bytes per item (at least 1). It judges only once the items added since the
warm-up are at least those held at it (the history has doubled, so one doubling of an array
cannot decide it), and fails past `slope_factor` (4) times the baseline with `soak: memory grew
faster than the history it holds since the warm-up`. On the healthy run the slope stayed at or
below 0.4 of its baseline. Its limit: a leak small beside the history (16 KiB/op adds about 600
bytes per item where the history costs about 2,000) does not move it; the teardown check is what
catches that.

**Budget.** At 1.5 GiB of live heap the soak stops after the epoch that reached it and reports
`soak: held for N operations, E epochs, peak P bytes, budget reached (L live bytes, limit B)`.
The check is at an epoch boundary, so the stop is the seed's (for one build), not the host's.
Six hours were estimated at 1.2 to 1.5 GB, close to the unit's 2 GB; the budget stops first,
and the teardown check still runs.

**Not done: reading only new decisions (Review B's NIT).** The decisions check reads every
decision whenever the revision moved, which makes a soak's cost per operation grow with its
history. Reading only the new ones would make the soak's check differ from the plain run's
(`sim_cluster <seed> K --liveness=false`) that a soak's failure replays as, so it stays; the
reach this costs is recorded in the earlier decision.

**The tooth.** `src/sim_soak_teeth_main.zig` switches on `c1_teeth.soak_leak` (16 KiB taken per
operation, never freed). `ops/sim-fleet/test-soak.sh`, in `zig build test` and so in `zig build
check`, runs it (Debug, seed 42, 300 operations) through `soak.sh` and the real reporter and
requires the issue `sim-soak: soak: memory still held after the world was torn down`; it also
runs a real held soak through the same path. `zig build sim-soak-teeth-exe` installs the tooth.
