# The long soak and the fleet's replay artefacts

*Decided 2026-11-14, by the slice (C3 slice 4, `docs/briefs/c3.md` items 6 and 7). The soak's
thresholds, the trace's length, `SIM_SOAK_MINUTES=360` and the unit's `MemoryMax=2G` are the
slice's picks, flagged for the supervisor. Nothing is deployed: the soak is opt-in on the owner's
host (`ops/sim-fleet/README.md`, item 8).*

**What #77 already gave.** Every issue and comment already carried the one-line replay of the
shrunk run (`git checkout <commit> && zig build ... && zig-out/bin/sim_cluster <seed> <ops> ...`).
Missing were an account of the run (the issue said what failed, not how the world got there) and
any run long enough to show a slow leak or a counter creeping toward its range.

**The trace (item 7).** The core keeps the last 24 operations in a ring (`OpTrace` in
`src/sim_cluster.zig`): index, virtual time from the run's start, the operation, the service it
acted on. It is printed after a failure's `step:` line. It draws nothing and is not hashed, so
no world changes: a passing report is byte for byte what it was, and a failing one differs only by
its `trace:` lines (checked on seeds of the base build against this one; numbers in the slice
report). 24 is enough to show the fault and what followed it in the failures seen so far, and
keeps the issue short; the fleet's block caps at 32 lines of 200 bytes, so a soak's detail lines
fit beside it. After `--shrink` the runner reruns the smallest failing run for its trace, because
the bisection's last run need not be the smallest. The trace is not in the fingerprint, so an
issue's identity is unchanged. Not traced: crashes (no report survives a panic; the `--trace-steps`
replay line stays the artefact), `sim-swarm` (its plan has no operation log yet) and
`store-faults`.

**The soak (item 6).** One seed, liveness off, as long as the budget allows. Without liveness the
world does not depend on the run's length, so a soak that stopped or failed at K operations is
exactly `sim_cluster <seed> K --liveness=false`: the replay needs no soak at all for a core
failure. Every epoch (500 operations) the core hands the shell an `Epoch` through
`Options.on_epoch`; the shell (`src/sim_soak.zig`) prints it with wall time and the heap's live
and peak bytes, and judges only what the seed decides:

- virtual time and the store's revision moved over the epoch (a wedged world);
- no counter has passed half its range: `u32` operations, transactions, steps and jobs; decisions
  against what the decisions check reads; the start ledger against its cap. Half, not full, so
  the soak warns while there is still a run to look at;
- live bytes per item of history held (store keys + log + revision + decisions + ledger) stay
  within 4 times their value at the fourth epoch. Retention keeps a week of virtual decisions,
  which a soak of hours never reaches, so the history keeps growing and an absolute bound would
  fail a healthy run; a ratio to what is held does not. 4 is loose on purpose: the ratio fell from
  about 2,870 to 1,900 bytes per item over the first 2,750 operations of seed 7.

Wall-clock speed is printed and never judged, so the verdict of a seed does not depend on the
host.

**The decisions check reads 1,024 pages.** It read at most 64 pages of 500 decisions and failed
the run past that ("there are more decisions than the check reads"). A run makes about 3
decisions per operation, so a soak would have failed near 10,000 operations on the check's own
bound. `decision_pages_max` is now 1,024 (512,000 decisions). It bounds the simulator's checker,
not the product, and no fleet run (800 operations at most) comes near either value.

**`--c1` soaks are refused.** The per-revision tap keeps its own copy of the history: about 1 GB
by 2,000 operations. A C1 soak needs that tap bounded first.

**Reach.** Operations per second fall as the history grows (166 at the start, 22 by 2,750
operations), because `MemoryStore` scans its whole table on every `get` and `list` (`docs/core.md`,
"The fleet's per-seed budget"; gdb samples of the soak put the time in `find`, `list_impl` and
`snapshot` under the controllers and retention). A soak of hours therefore reaches thousands of
operations, not millions. The fix is a hash index in `MemoryStore`, a `Store` change with its own
slice and the conformance suite as its gate; the soak's epoch lines are how its effect will show.

**Fleet plumbing.** `sim-soak` is a new `sim_fleet` kind (its summary line, `sim-cluster --soak:`;
replay step `sim-cluster-exe`). `ops/sim-fleet/soak.sh` runs beside `run.sh` with a state file of
its own, so the two loops never race; the daily tracker post stays `run.sh`'s, and a soak's seed
is counted only in the soak's state. A soak killed by a signal or a panic is recorded as `CRASHED`
with a replay one epoch past its last epoch line.
