# Zigcube: operating instructions

Zigcube is the orchestrator for Zigbox workloads, written in Zig. The coding handoff for C0 and C1 is [HANDOFF.md](HANDOFF.md); the wider design is Part II of Zigbox's `docs/SPEC.md` (repo `Zigbox/zigbox`), a snapshot of the live design doc (https://claude.ai/artifact/6D9js8mxSLYmfuZe3rQ26w). If they disagree, the live doc wins: stop and report the conflict rather than picking one.

## Rules

- **Read [HANDOFF.md](HANDOFF.md) and [DIAGNOSTICS.md](DIAGNOSTICS.md) before writing code.** HANDOFF's **Ask first** list binds you. Every failure path follows DIAGNOSTICS.md, which is shared with Zigbox: change both copies together, and treat Zigbox's as canonical.
- **Style and testing follow [docs/STYLE.md](docs/STYLE.md)** (Zigbox's TigerStyle rules, with Zigcube's departures at the top). Review rejects code that breaks it.
- **The web console lives in `web/`; read [docs/console.md](docs/console.md) before changing it.** Plain HTML, CSS and ES modules: no build step, no npm, and no request to any host but the server's own (no CDN, no web fonts). It follows [docs/api.md](docs/api.md), which is a proposal until the server exists; `web/mock/` implements it in the browser (`?mock=c0`, `?mock=c1`). Anything it shows that is not in `docs/keys.md` is a gap to report, not to invent.
- **Core modules stay `wasm32-freestanding`-clean, and CI enforces it.** The control-plane core (controllers, scheduler, API handlers, `Store`, `Runtime`, `Clock`, diagnostics: the list is `src/core.zig`) has no threads, sockets, files, libc, `std.Io` value, real clock or blocking call; the shell (HTTP, Postgres, SQLite, threads, the agent's runtime adapter) may import the core and never the reverse. `zig build wasm-check` and `zig build wasm-test` run in CI. Read [docs/wasm.md](docs/wasm.md) before adding a module to either side.
- Work one milestone at a time. Do not start a later milestone or build anything HANDOFF puts out of scope.
- A milestone is done only when its demo script passes start to finish on a clean machine. Unit tests passing, or code that compiles, is never reported as a passed demo. Say exactly what was and was not run.
- Each demo script becomes an automated test, `zig build demo-cN`. Never break an earlier demo: all prior `demo-cN` tests and the store conformance suite run in CI.
- When scope is in doubt, cut scope and keep the demo. Record the cut in the milestone's demo document, `docs/demos/cN.md`.
- Zig version is pinned in `build.zig.zon` (`minimum_zig_version`) and CI, matching Zigbox. Do not upgrade during a milestone.
- The pinned Zig is newer than most model training data, and std APIs (I/O, `std.Io`, readers and writers, the build system) changed in 0.15–0.17. `@cImport` is gone: C headers go through `b.addTranslateC`. Read the pinned std source (`zig env` prints ZON, and its `.lib_dir` field names the directory; `std` is under it) before using an API. Do not write from memory.
- `zig build` fetches the `zigbox` package pinned in `build.zig.zon` (a tarball of a Zigbox commit); Zig 0.17 unpacks it into `zig-pkg/`, which is ignored. Its diagnostics (`diagnostic`, `product`, `render`, `explain`) are Zigcube's too: `src/diag.zig` keeps the `ZC-` collector and registry and declares Zigcube's `Product`.
- The agent links Zigbox's `zigbox` module. Zigcube's `Runtime` interface follows what that module actually exposes. Report any gap between it and HANDOFF to the owner; don't paper over it.

## Disk

- The session's disk allowance is fixed and cannot be raised. Give each parallel worktree its own `ZIG_GLOBAL_CACHE_DIR`, and when `.zig-cache/o` grows large, empty it outside a build (`rm -rf .zig-cache`). Never delete another worktree's cache. `zig build pg-down` removes the throwaway Postgres.
- A build that was killed can leave `.zig-cache` half written, which then fails with `FileNotFound`; `rm -rf .zig-cache` fixes it.

## Environment facts (checked 2026-10-25 in the Claude Code cloud container)

- `.claude/hooks/session-start.sh` installs Zig 0.17.0 (checksum-verified) and libpq-dev, and puts `zig` and the Postgres 16 binaries on PATH.
- Postgres 16 is installed without the OrioleDB extension, so the plain-heap schema path is what runs here. `initdb` refuses root: run it as `postgres` in a directory that user owns, e.g. `su postgres -c "initdb -D $DIR -A trust -U zcube"`.
- SQLite 3 headers and the library are present.
- Zig downloads from https://ziglang.org/download/ work through the proxy.
- Zig's own package fetch does not work (`ConnectionResetByPeer`), and the proxy refuses `curl` of the pinned tarball (checked 2026-10-31). What works: `add_repo` for `Zigbox/zigbox` (read), `git clone --depth 1` it, `git fetch --depth=1 origin <commit from build.zig.zon>`, then `mkdir -p zig-pkg/<hash> && git archive <commit> | tar -x -C zig-pkg/<hash>`, with `<hash>` the `.hash` in `build.zig.zon`.
- A fresh container may lack Zig (run `.claude/hooks/session-start.sh` if `zig` is not on PATH) and has no `tester` user: `useradd -m tester` before `zig build check`.

## Commands

These arrive with the scaffold; keep this list current as they land.

- `zig build` builds `zig-out/bin/zcube`, `zcube-server` and `zcube-agent`. `zcube-server` needs
  the SQLite and libpq development files, embeds `web/` and the console's WASM module, and runs
  as `zcube-server [--config FILE] [--listen HOST:PORT] [--store memory|sqlite:<path>|postgres:<settings>]
  [--create-store]`; `--help` says the rest. Its writes are unauthenticated: listen on a private address.
- `zig build test` runs unit and snapshot tests (tidy's own tests included). `-Dtest-filter=NAME` runs only tests whose name contains NAME (the run is cached: to repeat one, run the binary under `.zig-cache/o/*/test` directly). It installs `zcube-agent` first: the `FakeRuntime` tests start real processes, each container under `zcube-agent supervise`, and skip if `zig-out/bin/zcube-agent` (or `ZCUBE_AGENT_EXE`) is not there. A test that dies can leave processes behind; `pkill -9 -f '[z]cube-agent supervise'` removes them.
- `zig build tidy` checks formatting and the mechanical style rules: 100 columns, 70-line functions, banned patterns, `catch unreachable` comments, no `and`/`or` inside `assert(...)`. Run it before every commit; CI does.
- `zig build test-store -Dbackend=memory|sqlite|postgres [-Dseed=N]` runs the store conformance suite. It always re-runs with a fresh seed (Zig's per-run test seed), prints nothing when it passes, and a failing test prints `seed=N`; replay with `-Dseed=N`. SQLite needs `libsqlite3-dev`, Postgres `libpq-dev` (the session-start hook installs it).
- `zig build test-store-faults -Dbackend=postgres|sqlite [-Dseed=N] [-Dpostgres=...]` (`src/store_faults.zig`) runs four client threads and a watcher against a real store, records every `Store` call and checks the history with `src/testing/history.zig`. Postgres goes through `src/testing/fault_proxy.zig` under a fault schedule drawn from the seed (latency, cuts at varied byte counts, stalls, partitions, the black hole, heal); ZC-E0213 is recorded as unknown. SQLite has no connection to cut, so it runs the same clients and checker without a proxy or faults. The seed is printed first (fresh unless given); a failure prints the verdict and the seed and exits 1. It fails, not skips, without a database. About 10 s per run; it is not part of `zig build check`. On Postgres it then runs the two failover runs of slice 10d (`src/store_failover.zig`, `docs/demos/c1.md`; `-Dfailover=false` leaves them out): `pg_dev pair-up sync|async` makes a primary and a streaming standby (ports `ZCUBE_PG_PAIR_PORT` and the next; directory `ZCUBE_PG_PAIR_DIR`; the defaults, `/tmp/zcube-pg-pair-<hash>` and a port from 21000 to 22998, come from a hash of the working directory, so worktrees do not share a pair), a real `zcube-server` runs on it, and the primary is crashed and the standby promoted mid-load: `sync` must lose nothing, `async` must halt the server with ZC-E0215. About 10 s each; `zig build pg-pair-down` removes a pair a killed run left (run it from the same worktree), and a run killed with SIGKILL leaves its `zcube-server`'s pid in `.zig-cache/store-failover-<mode>/server.pid`, which the next run of that mode kills first.
- **Server limits.** `zcube-server` holds at most `http_holds_max` (50) long-polling agent watches and serves `http_connections_max` (96) connections; each hold takes one Postgres connection, so a Postgres store needs `max_connections` of at least 80 (`store_postgres_watches_max` stays 64).
- **The Postgres test database.** `-Dbackend=postgres` takes the connection from `-Dpostgres=<libpq settings>`, else the `ZCUBE_TEST_POSTGRES` environment variable, else the server `zig build pg-up` starts (`host=127.0.0.1 port=55432 user=zcube dbname=postgres`). `zig build pg-up` runs a throwaway Postgres 16 as the `postgres` user in `/tmp/zcube-pg` (override with `ZCUBE_PG_DIR`, `ZCUBE_PG_PORT`; `ZCUBE_PG_BIN` if the Postgres programs are not on PATH) and prints the variable; `zig build pg-down` stops it and deletes the directory; `zig build pg-stop` stops it and keeps the data (`pg-up` starts it again). The suite creates a schema of its own per test in that database and drops it, so any database it may create schemas in will do. `zig build test` also runs the Postgres-specific tests, and skips those that need a database when `ZCUBE_TEST_POSTGRES` is unset; `test-store -Dbackend=postgres` fails instead of skipping.
- `zig build wasm` compiles the control-plane core for `wasm32-freestanding` (`zig-out/wasm/zcube_core.wasm`); `zig build wasm-check [-Doptimize=ReleaseSafe]` runs it in Node (installed here at `/opt/node22`) and checks its result; `zig build wasm-test` runs the core's unit tests under WASI in Node. See `docs/wasm.md`.
- `zig build sim-c0 [-Dseed=N] [-Dops=N]` runs the deterministic C0 simulation natively and as WASM and compares the reports (a simulation, never reported as `demo-c0`); `zig build sim-c0-exe` installs its native runner for loops over many seeds. See `docs/core.md`.
- `zig build sim-cluster [-Dseed=N] [-Dops=N] [-Dnodes=N] [-Dliveness=false] [-Dprofile=mixed|partitions|skew|crash_heavy|slow_store|auto] [-Dauto-shape]` runs the cluster simulation (N agents, a network, a store; one seed) natively and as WASM and compares the reports (a simulation, never `demo-c0`; duplicates are counted, not failed, until slice 6). `zig build -Doptimize=ReleaseSafe sim-cluster-exe` installs `zig-out/bin/sim_cluster <seed> <ops|auto> [nodes] [--liveness=false] [--heal-at=H] [--profile=NAME|auto] [--lease-ttl-ms=N] [--replicas-pct=N]` (a `--seeds` run with `--c1` ends in `sim-cluster --c1: seeds ...`, which the fleet requires for sim-c1), or `--seeds A..B <ops|auto> [nodes] [--shrink]`, which prints a replay command per failing seed and bisects `ops` to the smallest failing count. `--trace-steps` writes each step it enters to stderr (the fleet uses it to place a crash). `zig build sim-teeth` runs the same simulator with the agent's test-only fault on and passes only if a seed fails; `sim-teeth-exe` installs that runner. See `docs/core.md`, "The cluster simulation". `<ops>` = `auto` (`-Dauto-shape`) and `--profile=auto` draw the run's shape and fault profile from the seed, and `auto` operations also switch on `--strong` (opt-in; `mixed` and fixed operations are the old worlds bit for bit); a replay line names the concrete values. The drawn lease ttl runs from 8,000 ms, the shortest ttl the server admits (`fencing.inequality_problem`, ZC-E0121: #78 is fixed and the bound is the owner's, `docs/decisions/2026-11-06-renewal-before-fence.md`); a `--lease-ttl-ms` below it is refused. `docs/decisions/2026-11-04-fleet-profiles-and-shapes.md`.
- `zig build sim-c1 [-Dseed=N] [-Dops=N] [-Dnodes=N] [-Dprofile=...] [-Dauto-shape]` runs the cluster simulation with C1's checks (authority.md I1a I1b I2 I3 I4 I5 I6 I7 at every revision, plus the §5 evidence acceptance test at the end) natively and as WASM and compares the reports (a simulation, never `demo-c1`). `zig build -Doptimize=ReleaseSafe sim-c1-exe` installs `sim_cluster`; run it as `sim_cluster <seed> <ops> --c1` or `--seeds A..B <ops> --c1`; `--expect-fail --expect-symptom=I1b` is how the negative tests assert (`--expect-symptom=A|B` takes alternatives: the failure must start with one of them, `src/symptom.zig`; with `--expect-symptom-any` a seed that fails with another symptom is skipped, and the run passes only if some seed matches). B1 slices 5 and 6 add the job checks J1 J2 J3 J4 J5 J6 J7 J8 J9 (`--jobs=false` leaves the job workload out) and J10 (at rest, and a bound on refused reports after the heal) and thirteen teeth, `sim-c1-teeth-job_restart|claim|double|rewrite|cancel|deadline|deadline_late|deadline_offline|gap|stale|refused_loop|unclaimed|wipe` (B2 slice 4: with `--strong` (which `auto` operations and these two teeth, `job_wipe` and `job_unclaimed`, switch on; a replay line names it) every other host crash also loses the node's disk, state directory and containers (`wipes=` in the report), and every thirteenth job cannot be placed; without it a run is its old world bit for bit. A `.process` crash never wipes: a hand-deleted directory would leave containers this simulated node cannot list, which no agent can find (`docs/core.md`); all but `job_double` also run plain, without `--c1`, since J2 J4 J6 J7 J8 J10 need no per-revision tap; J4 also checks, before `finish`, that the client handled every ending up to its revision, and J8 fails a run no node started and nothing ended long after its `start_by_ms`). `zig build sim-c1-offline` runs the world of the `job_deadline_offline` tooth (long cuts, short deadlines) with the fix on, 30 seeds, and fails if any seed fails (J8 holds there). `zig build sim-c1-regressions` replays the sim-c1 runs that once failed (`c1_regressions` in `build.zig`, one command line each); each must pass; CI's sim job runs it. `zig build sim-c1-teeth` (or `sim-c1-teeth-allocation|readiness|skew|wedge|stale|locality`) must fail each check. `zig build sim-fencing-teeth` runs the simulator with the old `ttl / 3` renewal rule at a ttl of 4,000 ms (below the bound, lifted for it) and passes only if `fencing_settles` fails ("agents kept fencing"); about a minute; it runs in CI's sim job next to `sim-c1-teeth`, not in `check`. See `docs/core.md`, "sim-c1". `zig build sim-c1-regress` replays the fleet seeds of B2 slice 1 (#135 #137 #142 #143 #151 and seeds 31, 53, 102) and must pass; it runs in CI's sim job.
- `zig build sim-swarm [-Dseed=N] [-Dops=N] [-Dswarm-profile=mixed|liars|silent|refusers|honest|auto] [-Dauto-shape]` runs the swarm simulation (the C2 fetch plan and locality estimate against lying, silent and refusing peers; `docs/swarm.md`) natively and as WASM and compares the reports (a simulation, never a demo). `zig build -Doptimize=ReleaseSafe sim-swarm-exe` installs `zig-out/bin/sim_swarm <seed> <ops|auto> [--profile=NAME|auto]` or `--seeds A..B <ops|auto> [--profile=NAME|auto] [--shrink | --expect-fail]` (a failing seed prints `step: fetch|locality` and its replay; `--shrink` bisects the operations). `zig build sim-swarm-teeth` runs it with the plan's test-only fault on and passes only if a seed in 1..10 fails.
- `zig build sim-fleet-exe` installs `zig-out/bin/sim_fleet`, the simulation fleet's reporter: `sim_cluster --seeds A..B <ops> --shrink | sim_fleet ingest [--kind sim-cluster|sim-c1|sim-swarm] --commit SHA --state FILE [--repo OWNER/NAME --token-file FILE] [--tracker N] [--dry-run]` files each new failure as a GitHub issue (deduplicated by failing check and step) and comments on known ones (once per commit, at most 4 a day); `--kind` says which producer wrote the input (`sim-c1` is `sim_cluster --c1`, `sim-swarm` is `sim_swarm --seeds A..B <ops> --shrink`; the kind is part of the fingerprint and the daily post counts seeds per kind); `--dry-run` prints instead and keeps its state in `FILE.dry`. `--canary RUNNER --canary-seeds A..B [--expect-symptom TEXT[|TEXT...]]` (alternatives separated by `|`) reads a teeth canary's run and files a miss, a wrong symptom or a crash under `sim-canary`; `zig build sim-canary-exe` installs the fault-on runners and `share/sim-fleet/canaries.txt`, the cycle `run.sh` reads (generated from `c1_teeth_roots`; `ops/sim-fleet/README.md`, item 4). `ops/sim-fleet/run.sh` runs the three kinds each round (`SIM_FLEET_WORKERS_CLUSTER|_C1|_SWARM`, 1 each). Its unit tests, `ops/sim-fleet/test-canary.sh` and `test-crash-record.sh` run in `zig build test`. `ops/sim-fleet/README.md` says how to deploy the always-on runner.
- `zig build console-wasm` builds the console's browser module (`src/console_wasm.zig`, the real
  core over a memory store and the simulated runtime, ReleaseSafe) and checks it in Node under both
  V8 compilers: exactly one import (`env.zc_panic`), `GET /v1/status`, the C0 scenario, a reported
  panic, then `tools/pulls_check.mjs` (the Pulls screen's text helpers and the mock's `GET /v1/stats/pull`). `zig build console-site` also installs the whole console to `zig-out/console` for any
  static file server. `node tools/browser_check.mjs <url> --mode sim|server` is the dev-time
  Playwright check. See `docs/console.md`.
- `zig build agent-smoke` starts `zcube-server` (SQLite) and one `zcube-agent` with `FakeRuntime` as real processes and checks them on the host: 3 replicas as 3 commands under 3 supervisors, a `kill -9` replaced, an agent restart with no duplicates, a server restart that changes nothing, an unknown digest held with `ZBX-E0410`, and a job (B1 slice 4): claimed, started once, adopted after `kill -9` of the agent, its exit code recorded. It kills everything it started, even on failure. **It is not `demo-c0`.** About 35 seconds. `docs/agent.md` describes the agent.
- `zcube-agent --node NAME --server HOST:PORT --state-dir DIR --cpu-millis N --memory-bytes N` runs the node agent (`--help` for the rest; a ZON file works too). Containers are plain host processes under supervisors of their own, so stopping the agent leaves them running and a restart adopts them. Test faults: write `oom`, `pid_limit` or `lost` into `<state-dir>/faults/<replica id>`.
- `zig build local-smoke` (`src/local_smoke.zig`) runs `zcube local up`, a second `up`, `apply`, `down`, `up` (replicas adopted, supervisors unchanged), `down`, `down`, two concurrent `up`s and a `down` after the agent died on copies of the executables the build made, in a scratch directory, and kills everything it started even on failure. About 10 s; not in `check`; not `demo-c0`. `docs/cli.md`, "local up and down".
- `zig build bench-watch` (`src/bench_watch.zig`) is c1.md's "Watch fan-out" row: a real `Server` over SQLite with 50 held agent polls in one process and 2,000 preloaded assignments; 100 rounds of one new assignment each. It prints one line, `bench-watch: agents 50 assignments 2000 held H refused R woken W of 50 p50 .. ms p99 .. ms limit 250 ms PASS|MISS`; exit 1 on a miss (too slow, more than one agent woken, or an agent refused a hold: `http_holds_max` is 50), 2 when the run is invalid (the control plane wrote something of its own). About 15 s; not in `check`.
- `zig build demo-c0 -Dbackend=sqlite|postgres [-Dtranscript=FILE]` runs HANDOFF's C0 demo for real: `zcube-server`,
  one `zcube-agent` with `FakeRuntime` and the `zcube` command as processes, every outcome asserted,
  a transcript printed (about 25-50 s). The Postgres run uses `-Dpostgres=` / `ZCUBE_TEST_POSTGRES` like `test-store`,
  owns that database's `zcube` schema (it drops it before and after), and stops and starts the database with
  `pg_dev stop` / `pg_dev up` (`zig build pg-stop`, `pg-up`) or with `ZCUBE_DEMO_PG_STOP` / `ZCUBE_DEMO_PG_START`.
  `docs/demos/c0.md` says what it asserts. Not `zig build sim-c0`, which is a simulation.
- `zig build check [-Dcheck-user=<user>|-]` runs every gate a slice must pass and ends in one line,
  `check: PASS <commit> (build test tidy errors-site wasm-check wasm-test console-wasm mtls-teeth store:memory,sqlite sim-c0 sim-cluster sim-teeth sim-c1 sim-swarm sim-swarm-teeth, test as tester)`
  or `check: FAIL <commit> (what failed)`. The gates are build-step dependencies; then
  `src/testing/check.zig` runs the Postgres suite (only when `ZCUBE_TEST_POSTGRES` is set), `sim-c0` and
  `sim-cluster` (40 operations) each with a fresh seed (printed as `sim-c0: seed N`, `sim-cluster: seed N` first), `sim-teeth`, `sim-swarm` (100 operations, fresh seed, printed as `sim-swarm: seed N`), `sim-swarm-teeth` and, as root, `zig build test` as `tester` in a scratch
  worktree of HEAD (`-Dcheck-user=-` skips it; `useradd -m tester` creates the user). That run's
  caches are kept in `.zig-cache/zcube-check-cache` (tester-owned, about 0.4 GiB, emptied past 8 GiB;
  `rm -rf .zig-cache` resets it), so only the first check of a worktree builds from nothing
  (`docs/decisions/2026-11-06-check-keeps-tester-cache.md`). `+dirty` after the commit
  means uncommitted changes the user run did not see. It leaves out `agent-smoke` and `demo-c0`.
- `zig build demo-c1 -Dbackend=sqlite|postgres [-Dtranscript=FILE]` runs HANDOFF's C1 demo for real:
  `zcube-server` with `--lease-ttl-ms 8000`, three `zcube-agent`s with `FakeRuntime` (node1 behind a
  fault proxy), the `zcube` command; join, 6 replicas two per node, power off node3 and replacement,
  restart and `zcube why node`, the partition test, local mode. About 35 s; uses the Postgres like
  `test-store`. `docs/demos/c1.md` says what it asserts. Not `sim-cluster`.
- `zig build swarm-smoke` (`src/swarm_smoke.zig`) runs `zcube-server` and three `zcube-agent`s with `FakeRuntime` and a fake registry (one chunk of at least 1 MiB; node 3's registry link is black-holed): the first image is fetched from the registry, the second from a peer, a corrupting peer is struck (ZC-W0601), and the third replica starts with the registry unreachable. `swarm-smoke-teeth` runs it against `zcube-agent` built with verification skipped and passes only if the smoke fails. About 30 s; not in `check`; not a demo. A fetch's stderr is `<container dir>/fetch.log`; `zcube-agent --registry HOST:PORT` (needs `--images-dir`) enables it. `docs/agent.md`.
- `zig build mtls-interop` (`src/mtls_interop.zig`, `ops/mtls-interop/InteropServer.java`) runs the TLS client of `tls_conn.zig` against stock servers, `openssl s_server` and a JDK 21 `SSLServerSocket` (compiled with `javac` per run; `ZCUBE_JAVA_HOME` names the JDK), with certificates of the Zigcube PKI: accepted and refused client certificates (chain, expiry, name, allow-list), TLS 1.2 refused, the identity extension read back by both servers, SSE and bulk streams, KeyUpdate. It fails, not skips, without `openssl`, `setpriv` (util-linux) or a JDK 21 (`docs/decisions/2026-11-06-interop-needs-setpriv.md`). A couple of minutes; not in `check`; not a demo. `docs/decisions/2026-11-05-interop-tools-are-test-only.md`.
- `zig build mtls-teeth` runs the mTLS tests named `teeth:` (each skipped security check must be caught); it is in `check`, and `wasm-check` runs `src/mtls_smoke.zig` in the WASM module. `docs/mtls.md`.
- `zig build demo-cN` runs milestone N's demo.

## Working as the implementer

- Work in slices as the brief defines them (`docs/briefs/`). At the end of each slice, commit and stop with a report. The supervisor reviews each slice adversarially; what the review finds is fixed before the next slice, by a fresh session (see below).
- In a cloud session the container is ephemeral, so push each slice to your own session branch. Never push to `main`, and never to another session's branch.
- **Before you report, run [REVIEW.md](REVIEW.md) on your own diff**, and say which of its items your slice touched and what you checked.
- **Gates, on the commit you report:** `zig build check`; paste its last line (`check: PASS <commit>`, without `+dirty`). A report without that line, or with another commit's, is not a report. It does not run `agent-smoke` or `demo-c0` (CI does), nor the Postgres suite unless `ZCUBE_TEST_POSTGRES` is set: when the store changed, set it (`zig build pg-up` prints it) so the PASS line names `postgres`.
- Stop and ask the supervisor before a change alters a user-visible bound, limit or default, or registers a new code; give the evidence and the choice. Do not pick one and leave it to review.
- Run long commands (`zig build check`, sweeps) in the background and wait for them to finish; do not poll with sleep loops. Kill what earlier runs left before running again.
- Run every gate once, on the final commit, then push once. Never push before the gates finish.
- Report what you ran and its output (the last lines, not the log), what you did not run and why, every deviation from HANDOFF or the brief, and anything in HANDOFF, DIAGNOSTICS or the Zigbox code that seemed wrong. End the report with the handoff note described below.

## Agent context discipline

An agent re-reads its whole context on every turn, so cost grows with context size, not with the work done. Keep implementer context small. (Adopted from Zigbox, 2026-10-30.)

- **One session per slice.** The supervisor starts a fresh implementer session for each slice of a milestone. Do not resume a finished implementer for the next slice or for follow-up fixes.
- **Hand off through the repo.** Before stopping, the implementer commits its work and ends its report with a handoff note: decisions made, traps found, what's next. Lasting decisions go in [docs/decisions/](docs/decisions/), one file per decision (`YYYY-MM-DD-<slug>.md`, see its README), never in a shared file, so parallel branches do not conflict. The next implementer starts from the brief, the branch and that note.
- **Context ceiling.** Stop at about 250K tokens of context or 60 turns, whichever comes first. At that point, reach the next safe stopping place, commit, write the handoff note and report. The supervisor enforces this and starts a new implementer rather than extending the current one.
- **Small fixes get new sessions.** For a bug or review finding, start a fresh session with the symptom and the relevant commit. Do not send it back to the session that wrote the code.
- **Keep noisy output out of context.** Redirect `zig build` and test output to a file and read only the failing lines. Do not paste full logs.
- **Delegate lookups.** Send broad reads, such as searching the Zig std source or the pinned Zigbox package, to a read-only Haiku agent and keep only the answer.
- **Purely mechanical work goes to Haiku** (owner, 2026-10-30). A change fully specified by a pattern (threading an argument through call sites, a rename, copying generated output into a doc, a status update, a CI tweak) is done by a Haiku subagent or session, given the exact pattern; whoever delegated checks its diff. Anything that needs judgment (design, tests, invariants, review) stays with Sonnet or the supervisor. Briefs name a slice's mechanical parts.
- The supervisor follows the same rules; its own handoff is [docs/supervisor-handoff.md](docs/supervisor-handoff.md).

## Reviews on GitHub (owner, 2026-11-05)

Every adversarial review of a pull request (a slice review, a re-review, either release reviewer) is posted on that pull request as a GitHub pull request review, so the record stays with the PR.

- One review per pass, with the event `COMMENT`. A review never approves or requests changes: the sessions post from the PR author's account, and merging stays with the supervisor and the owner.
- The review body opens with the verdict (merge, merge after MUSTs, or rework), then what the reviewer ran and did not run, then any finding that has no line to attach to.
- Each finding that belongs to a line is an inline comment on that line of the diff, starting with its tag: **MUST**, **SHOULD** or **NIT**, and stating a concrete failure scenario.
- The reviewer posts the review and nothing else on GitHub. The two release reviewers stay independent: neither reads the other's review before posting its own.
- The fix session works from the posted review. The supervisor still relays the verdict to the owner.

## README and site status

- [README.md](README.md) holds the status of every milestone and slice: what is built and reviewed, what is in review, and what is not started. The supervisor updates it in the same push that changes the status. Never mark anything "demonstrated" until its `demo-cN` job is green in CI.
- The project site (`site/index.html`, the `SITE` and `MILESTONES` data at the top of its script) shows the same status. Update it in the same push as the README: the milestone's `status`, its `slices` count and, once a demo is green in CI, its `demo` lines taken from that run's recorded output, with `recorded` linking to the run (`{url, date}`), which renders the "recorded in CI" badge. Never show output that was not recorded as recorded. Pages deploys only from `main`.

## Releases (owner, 2026-11-04)

A release (a tag, and any milestone that ships) is cut only from a commit that is all of:

- **Sim-clean.** The simulation fleet has run on that commit for 24 hours, with every simulator the
  milestone gates on (today `sim-cluster`, its `--c1` checks and `sim-swarm`), and no `sim-fleet`
  issue is open against it; `zig build check` passes on it.
  (C2 alone ships without the 24 hours: docs/decisions/2026-11-04-c2-ships-without-fleet-soak.md.)
- **Jepsen-clean,** once the Jepsen battery exists (a C5 prerequisite,
  [docs/decisions/2026-11-03-jepsen-before-c5.md](docs/decisions/2026-11-03-jepsen-before-c5.md)):
  the battery passes on that commit.
- **Reviewed adversarially by two independent Opus reviewers.** Each is a fresh session given the
  diff since the last release and the briefs, not the other's findings nor the implementers'
  conclusions. Every MUST from either is fixed, or the owner accepts it in writing in
  `docs/decisions/`, before the release.

The release PR (or the supervisor's report) quotes the fleet's tracker line, the Jepsen result
when it applies, and both review verdicts.

Every release also gets a quick retro, written by the supervisor within a day of the release and
kept short: what assumptions turned out to be off base, what each cost, and what changes because
of it. It goes in `docs/retros/<version>.md` (one file per release), and any rule it changes lands
in this file or `docs/decisions/` in the same PR.

## Git

- Develop on the branch you were given and commit in small, meaningful steps, signed off (`git commit -s`, DCO). Licence is Apache 2.0; there is no CLA.
- Never report an unpushed commit as pushed.
- CI runs only on pull requests and on `main`, never on a plain branch push. When a change needs CI, open a PR (or push to an open one); don't push just to trigger CI, and batch small follow-ups into one push. Actions time is limited.
- On a pull request CI runs only the jobs a change's paths can affect (`.github/ci-changes.sh`, table-tested in `.github/ci-changes-test.sh`; [docs/decisions/2026-11-04-ci-speed.md](docs/decisions/2026-11-04-ci-speed.md)). A path no rule names, a push to `main`, a `claude/release-*` pull request and a pull request labelled `full-ci` run everything. If you are unsure, add `full-ci`. Add a row to the table test when you add a rule.
- A change that touches only documentation (every changed path is a `.md` file outside `web/` and `src/`, or lies under `site/` outside `site/errors/`) skips CI's jobs, as the `changes` job in `ci.yml` decides. That does not change when a commit may carry `[skip ci]`.
- A commit that only records status (README.md and `site/index.html` updated after a CI result) carries `[skip ci]` in its message, so it does not start a run of its own. Never use `[skip ci]` on a commit that changes code, tests, CI or generated files.
