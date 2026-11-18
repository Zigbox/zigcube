# CI speed: the sim-c1 teeth and worlds in shards, and the relay copy fuzz bounded on progress
*Decided 2026-11-17, by the supervisor (the owner asked for CI to be faster again).* Follows
[2026-11-04-ci-speed.md](2026-11-04-ci-speed.md) and
[2026-11-09-sim-job-split.md](2026-11-09-sim-job-split.md).

## Before

Wall minutes per job, from the GitHub API, runs of `ci.yml` on `main` (warm means the job's
cache entry matched exactly; every other run restored an older entry or none):

| Run | sim-c1 negative tests | sim-c1 worlds | format, build, test | simulations | demo-c2 | wasm |
|---|---|---|---|---|---|---|
| 44174653042 (#277, warm) | 1.8 | 14.8 | 10.3 | – | 8.2 | – |
| 44143398079 | 27.5 | 25.4 | – | – | – | – |
| 44020895061 | 27.9 | 21.8 | 7.5 | 10.0 | 7.5 | 7.0 |
| 43749498027 | 24.2 | 21.5 | 10.7 | 11.5 | 10.3 | – |
| 43737640333 | 25.4 | 23.3 | 12.2 | 9.5 | – | – |

(– : not among the longest jobs of that run.) The critical path was the negative tests at 24 to
28 minutes whenever `src/` changed, then the worlds at 21 to 25; the next job, `format, build,
test`, takes 7.5 to 12.

Why each is long:

- **The negative tests are compile-bound.** Each of the 33 teeth is a ReleaseSafe executable of
  its own (its root sets one comptime switch), about 56 s to compile in CI at about 1 GB. Locally
  one took 88 s with the build runner's setup, four at once 166 s: about 1.7 compiles at a time
  on four cores, so 33 take about 25 minutes. Running them takes little; on an exact cache hit the
  whole job is 1.8 minutes. A change to `src/` misses the exact key, and every tooth imports most
  of the core, so every tooth recompiles.
- **The worlds are run-bound and serial.** The six steps ran one after the other, and inside each
  step one `sim_cluster --seeds A..B` process ran its seeds in turn, so one core of four worked.
  In 44020895061: burst 5.9, worlds 6.3, reuse 3.7, signed 2.0, offline 1.4, runs-unread 0.9,
  plus 1.2 to 1.8 minutes restoring the cache.

## What changes

1. **`sim-c1-teeth` takes `-Dteeth-shard=I -Dteeth-shards=N`** (default 0 of 1, every tooth): the
   step then runs the teeth whose index in `c1_teeth_roots` is I modulo N, with their extra seed
   ranges and plain runs. The N shards together are the whole table, and a tooth added later
   falls into one of them with no edit here. A shard out of range fails the step at once and
   compiles nothing. Each `sim-c1-teeth-<name>` step and `sim-c1-teeth-exe` are unchanged.
2. **CI runs the negative tests as a matrix of four** (`simulations (sim-c1 negative tests, shard
   I of 4)`), 9, 8, 8 and 8 teeth, each shard with its own cache entry
   (`sim-c1-teeth-<I>`). Expected cold: about a quarter of 25 minutes plus setup, 8 to 9 minutes.
3. **The world steps split their seeds over processes** (`add_seed_ranges` in `build.zig`):
   burst one seed per process (it was 1..2, 14, 17, 21), worlds one per process (the 225 replay
   stays its own), reuse ten seeds per process, signed five, offline ten. A `--seeds A..B` run
   passes only if every seed in it passes (`sim_cluster_main.zig`: exit 0 only when `failures` is
   0), and no world root makes a judgement across seeds, so the same seeds are judged by the same
   rule; no seed, operation count or flag changes. The build runner runs independent Run steps
   side by side, so one `zig build` uses every core.
4. **CI runs the worlds as a matrix of two**, each one `zig build` of three steps so they share the
   cores: `burst` (sim-c1-burst, sim-c1-offline, sim-c1-runs-unread; about 8 CPU-minutes) and
   `evict` (sim-c1-worlds, sim-c1-reuse, sim-c1-signed; about 12), each with its own cache entry
   (`sim-worlds-burst`, `sim-worlds-evict`). Expected: 5 to 7 minutes each.
5. **The cache.** Ten jobs now use `.github/actions/zig-cache`. A teeth shard's entry holds only
   its share of the teeth, so the four together are about the size of the old single entry
   (605 MB); the two worlds entries each hold the sim runners only. GitHub evicts the least
   recently used entries past 10 GB, and the 2000 MB guard per entry is unchanged.

Nothing is dropped: every check, tooth, seed and operation count runs as before, and
`ci-changes.sh` routes the same paths to the same jobs (`.github/` runs everything; the table test
gains a row for `.github/actions/zig-cache/action.yml`).

Job names change: `simulations (sim-c1 negative tests)` becomes four names with `shard I of 4`,
and `simulations (sim-c1 worlds)` becomes `(sim-c1 worlds, burst)` and `(sim-c1 worlds, evict)`.
A branch protection rule that names the old checks must be updated, and it must not name the
matrix jobs: when a matrix job's `if` is false (a documentation-only change) GitHub reports one
skipped check under the unexpanded name (`... shard ${{ matrix.shard }} of ...`), so a required
check on `shard 0 of 4` would wait forever on such a change. The `simulations (sharded jobs)` job
(`sim-shards`) `needs` both matrices, runs always, and succeeds when each result is `success` or
`skipped`, so a required check names that one job. `main` is not protected today, so nothing
breaks now; whoever adds a rule requires `simulations (sharded jobs)`, not the shard names.

The shard count is written once, as the matrix's entries: the step passes `strategy.job-total` as
`-Dteeth-shards`. Timeouts of the sharded jobs are 20 minutes (the slowest cold run was 10.4).
Each sharded job's cache entry is limited to 1000 MB (the action's `limit-mb`; the other four
keep 2000), which keeps the ten entries' ceiling at 14 GB rather than 20.

## After

The `full-ci` run of this pull request, 44198072571 (head fdff7ee), every job green. Each new
shard's cache entry did not exist yet, so all of them ran cold, which compares with the cold runs
above:

| Job | Before (cold) | After (cold) |
|---|---|---|
| sim-c1 negative tests | 24.2 to 27.9 | shards 8.6, 9.1, 10.2, 6.0 |
| sim-c1 worlds | 21.5 to 25.4 | burst 10.4, evict 7.8 |
| format, build, test | 7.5 to 12.2 | 12.7 |
| demo-c2 | 7.5 to 10.3 | 9.9 |
| simulations (sim-c0, sim-c1) | 9.5 to 11.5 | 7.5 |

The longest job fell from 24 to 28 minutes to 12.7, and it is now `format, build, test`, which
this change does not touch. The longest shard (worlds, burst: sim-c1-burst's five seeds of about
165 s each, side by side with offline and runs-unread on four cores) is 10.4. The run's wall clock
was 22 minutes from the first job queued to the last finished, including waiting for runners: 21
jobs compete for the account's concurrent runners.

## The relay copy fuzz timed out under load

`fuzz: the copy loop over TLS records split and fragmented at random moves every byte`
(`src/relay_tls_test.zig`, `tls_copy_once`) failed once with `error.Timeout` in a local
`zig build check`. The job side set one deadline, `deadline_ms` (5 s), for the whole stream: up to
three relay buffers sent through a socket with a one-byte receive buffer, with random pauses of
up to 4 ms on the job side and pieces with pauses on the upstream side. That is about a second on
an idle machine and can pass 5 s when `check` compiles and tests on every core. The upstream
thread already bounded each record on its own.

The deadline now bounds the time without progress: it is set again whenever a byte is written to
or read from the relay. What the test checks is unchanged: a byte lost or stuck stops progress and
still fails as `Timeout` within `deadline_ms`, and a byte repeated or out of order still fails as
`WrongBytes`. The setup is not retried, and the assertion never is.

Not reproduced here on demand: the old binary passed 10 iterations three times under 16 busy loops,
and twice pinned with 6 busy loops to one core. The fixed test passed 10 iterations pinned to one
loaded core, and runs in `zig build test` as before.
