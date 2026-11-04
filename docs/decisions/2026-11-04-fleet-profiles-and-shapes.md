# Fleet profiles and shapes (C3 fleet 1)

Brief: `docs/briefs/c3-sim-fleet.md`, items 1 and 2. Code: `src/sim_shape.zig`,
`sim_cluster.plan`, `sim_swarm.resolve`.

## Decisions

**Opt-in, `mixed` and a fixed shape stay the default.** `profile = mixed` is the world every
earlier build drew, bit for bit (the profile is a mask applied after the unchanged base draw),
and an explicit `<operations>` keeps the seed-picked node count, the 10 s lease ttl and 100 %
replica counts. So pinned-seed regression tests, the teeth runners and the fleet's current
command line are unchanged. `auto` is asked for: `<operations>` = `auto`, `--profile=auto`
(`-Dauto-shape`, `-Dprofile`, `-Dswarm-profile` in `zig build`). `zig build check` runs its
fresh seed with `-Dprofile=auto` / `-Dswarm-profile=auto` at fixed operations.

**Every draw has its own generator** (seed xor a salt), so a seed replays and one draw never
moves another. The replay line names the concrete values (`--profile=`, `--lease-ttl-ms=`,
`--replicas-pct=`, nodes, `--heal-at=`), so a replay needs no draw.

**Cluster profiles** (weights 3 2 2 2 2): `mixed` (the seed's own mix), `partitions` (network
faults and partitions only), `skew` (clock-rate error and suspends), `crash_heavy` (agent and
server crashes, runtime faults, sim-c1 freezes), `slow_store` (store outages, lost
acknowledgements, slow links). Each other profile zeroes every fault class but its own and
forces its own on.

**Swarm profiles** (weights 3 3 2 2 1): `mixed`, `liars`, `silent`, `refusers`, `honest`. A
non-mixed profile turns every peer the mix made misbehave into the profile's one kind (one peer
if the mix drew none); `honest` makes all honest.

**Shape**: nodes 1-2 (20 %), 3-4 (35 %), 5-8 (30 %), 9-16 (15 %); lease ttl the shipped 10 s
40 % of the time, else uniform 5,000-10,000 ms; replica counts 100-300 % of the usual (capped as
before by the node count); operations 40-99 (45 %), 100-199 (35 %), 200-399 (20 %), and one run
in ten ("long") uniform 400-800, with operations times nodes at most 5,000 (`cost_max`; the run
loses operations, never nodes).

## Deviations from the brief, and why (measured)

- **Operations stop at 800, not 5,000.** A cluster run costs about operations^1.8 and grows
  with nodes and replicas (ReleaseSafe, 3 nodes: 100 operations 1.3 s, 400 6.7 s, 800 24 s; 12
  nodes 2.8 s / 11.7 s / 43 s). 5,000 would take tens of minutes a run, the range deadline is 100
  seeds in 1 hour. Two earlier caps (1,500 and 1,000 operations, replicas up to 800 %) left
  8-10 of 100 seeds above 120 s each; the shipped ones were timed on seeds 1..100 with `auto` (four runs in parallel on four cores,
  ReleaseSafe, each run cut at 120 s): mean 14 s a run counting the cut ones as 120 s, 4 cut
  (seeds 12, 27, 44, 69, all `partitions`: 164 s for seed 44, which `mixed` runs in 71 s), none
  failed. That is about 25-30 minutes a range of 100 run one after the other, inside the
  hour; `partitions` with many nodes is the slow corner and the first knob to turn.
- **Lease ttl is drawn from 5,000 ms, not just above the fence margin (3,000).** See the bug.
- `cost_max`, `operations_max` and `long_share_denominator` are constants in `sim_shape.zig`;
  raising them is one line, and the next release should re-measure.

## Real finding, not fixed here (brief: report, do not fix)

**A lease ttl of 4,500 ms or less makes a healed cluster fence again and again.** With one
node and a fault-free workload after healing, the agent fences (stops its containers for the
lease) every second or so, writes grow, and the run becomes quadratic: 60 operations take 0.3 s
at ttl 10,000, 0.4 s at 5,000, 4.3 s at 4,500, 5.6 s at 4,000, 14 s at 3,500. `fencing.zig`
allows these (ttl above the margin). Replay:
`zig-out/bin/sim_cluster 3 100 1 --lease-ttl-ms=4000` (does not finish in 110 s;
`--trace-steps` shows it stopped in convergence). Either the inequality needs a margin for the
renewal cadence or the agent's renewal is wrong near the margin; the shapes stay at 5,000+.

## Limit found by the 2,000-seed sweep: the same failure reaches TTLs above 4,500 ms

`sim_cluster --seeds 1..2000 auto --profile=auto` (ReleaseSafe, each seed run alone under a
150 s cap): 1,951 pass, 7 fail, 42 are cut at the cap. All 7 failures are one check, "an agent
took too many steps for the time it was up (a busy loop)", all under `crash_heavy`, with lease
ttls 5,040 to 6,172 ms (nodes 1 to 6, replicas 100 or 300 %). Replays (the printed lines):

| seed | replay | ttl 10,000 |
|---|---|---|
| 254 | `sim_cluster 254 378 3 --profile=crash_heavy --lease-ttl-ms=5181 --replicas-pct=300 --heal-at=347` | holds; also at 8,000, fails at 6,000 |
| 343 | `sim_cluster 343 736 1 --profile=crash_heavy --lease-ttl-ms=5129 --replicas-pct=100 --heal-at=700` | holds; fails at 7,000 |
| 478, 551, 1468, 1698, 1841 | `--seeds N..N auto --profile=auto` prints each line | not replayed at other ttls |

That is the failure of #78 (a short ttl makes agents fence again and again) with a wider reach
than #78 states: seed 343 fails at 7,000 ms. It is a core issue, not the shape code, and is not
fixed here. **Until #78 is fixed, a `crash_heavy` run with a ttl below about 8,000 ms is likely to
fail**; only seeds 254 and 343 were replayed at other ttls. The draw floor stays at 5,000 ms (the
brief's lower bound and what the sweeps above ran with), so the fleet will report this failure at
about 0.35 % of `auto` seeds; raising the floor to 8,000 ms is one line in `sim_shape.zig` and the
owner's call (it would hide the failure from the fleet, not fix it).

## Fleet follow-ups (not done: `ops/sim-fleet/`, `src/sim_fleet*` are PR #71's)

- `parse_summary` now reads the `auto` summary (`drawn operations`; done). A failure also prints
  `  profile:` and `  shape:` detail lines, which the parser ignores. `ops/sim-fleet/run.sh` still
  passes explicit operations; moving it to `auto` is the next step.
