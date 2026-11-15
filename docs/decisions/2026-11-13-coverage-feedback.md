# Coverage feedback: counters in the report, a book per commit, one round in two biased

*Decided 2026-11-13, by the slice (C3 slice 3, `docs/briefs/c3-sim-fleet.md` item 5). The default
`SIM_FLEET_BIAS_ONE_IN=2` and `seeds_min=100` are the slice's picks, flagged for the supervisor.*

**Counters.** `sim_cluster` counts, per run, the checks it evaluated, the faults it injected, the
operations it drew and the code paths it reached (`src/sim_coverage.zig`, a core module; names and
groups in `docs/core.md`, "Coverage"). Every counter reads a tally the world already keeps, or is
a plain increment beside one (`ops_drawn`, the check ids, the decision actions); none draws, so no
seed's world changes. The lines print after `world hash`, only on a passing run: the report
without them is an exact prefix of the report with them, the native and WASM reports still compare
equal, and the fleet's ingest parser ignores `coverage:` lines (it reads only failures and the
summary). Proof: seeds 1..200 of `sim_cluster <seed> auto --profile=auto` and of the same with
`--c1`, the build before the slice against the build with it, each report with `coverage:` lines
removed: identical, and the exit status the same (numbers in the slice report).

`check.<id>` counts only checks that go through `check()`; the per-revision C1 checks that judge
through their own verdicts show as `check.revision`, `check.guarded_write` and the like, which are
the counts those checks already keep. At most 128 names; past that a run prints `dropped=N`
rather than grow the report (about 2 KB of coverage per report today, about 90 names with `--c1`).

**The book.** `sim_cluster --seeds` adds, before its summary, one line per profile it ran:
the seeds of that profile and, for each name, how many of them reached it (count above 0).
`sim_fleet coverage` adds those lines to `state/coverage.txt`, keyed by kind, profile and name,
for one commit; a new commit starts it over, since a change to the simulator changes what a seed
reaches. A line where reached exceeds seeds, or an unknown profile, is refused (exit 1) and the
book is left as it was (written to `FILE.new`, then renamed).

**The bias.** `sim_fleet bias` picks, for a kind: any profile with fewer than 100 seeds of this
commit (fewest first), so every profile is sampled before one is judged; else the name with the
fewest seeds reaching it across profiles (among names some seed reached: a name no seed reaches
has no profile to steer toward), and the profile that reaches it in the highest share of its
seeds. `run.sh` uses it one round in `SIM_FLEET_BIAS_ONE_IN` (default 2), only when
`SIM_FLEET_PROFILE` is `auto`, so half the rounds still draw from the seed and the biased half
cannot starve a profile. A biased round passes `--profile=P` to its workers and replay lines; its
seeds are counted under their kind in the tracker exactly as before.

**Cut.** `sim-swarm` has no counters and is never biased: its five profiles already run 50,000
seeds a batch each, so the fleet has nothing to steer there yet. Steering by shape (nodes, ttl)
rather than profile is left out: a replay line already names the shape, and a fixed shape would
narrow what `auto` explores.

Where: `src/sim_coverage.zig`, `src/sim_cluster.zig` (`record_coverage*`),
`src/sim_cluster_main.zig` (`Reach`), `src/sim_fleet_coverage.zig`, `ops/sim-fleet/run.sh`
(`bias_pick`, `coverage_add`), `ops/sim-fleet/README.md` item 6, `docs/core.md` "Coverage".
