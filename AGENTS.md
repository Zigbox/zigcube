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
- Zig's own package fetch does not (`ConnectionResetByPeer` at `build.zig.zon`), and `zig fetch <file>` stores a tarball that the build then unpacks under the wrong hash. Download the pinned tarball with `curl -sSL -o <file> <url from build.zig.zon>` and unpack it by hand: `mkdir -p zig-pkg/<hash> && tar -xzf <file> -C zig-pkg/<hash> --strip-components=1`, with `<hash>` the `.hash` in `build.zig.zon`. (Checked 2026-10-30.)
- A fresh container may lack Zig (run `.claude/hooks/session-start.sh` if `zig` is not on PATH) and has no `tester` user: `useradd -m tester` before `zig build check`.

## Commands

These arrive with the scaffold; keep this list current as they land.

- `zig build` builds `zig-out/bin/zcube`, `zcube-server` and `zcube-agent`. `zcube-server` needs
  the SQLite and libpq development files, embeds `web/` and the console's WASM module, and runs
  as `zcube-server [--config FILE] [--listen HOST:PORT] [--store memory|sqlite:<path>|postgres:<settings>]
  [--create-store]`; `--help` says the rest. Its writes are unauthenticated: listen on a private address.
- `zig build test` runs unit and snapshot tests (tidy's own tests included). It installs `zcube-agent` first: the `FakeRuntime` tests start real processes, each container under `zcube-agent supervise`, and skip if `zig-out/bin/zcube-agent` (or `ZCUBE_AGENT_EXE`) is not there. A test that dies can leave processes behind; `pkill -9 -f '[z]cube-agent supervise'` removes them.
- `zig build tidy` checks formatting and the mechanical style rules: 100 columns, 70-line functions, banned patterns, `catch unreachable` comments, no `and`/`or` inside `assert(...)`. Run it before every commit; CI does.
- `zig build test-store -Dbackend=memory|sqlite|postgres [-Dseed=N]` runs the store conformance suite. It always re-runs with a fresh seed (Zig's per-run test seed), prints nothing when it passes, and a failing test prints `seed=N`; replay with `-Dseed=N`. SQLite needs `libsqlite3-dev`, Postgres `libpq-dev` (the session-start hook installs it).
- **The Postgres test database.** `-Dbackend=postgres` takes the connection from `-Dpostgres=<libpq settings>`, else the `ZCUBE_TEST_POSTGRES` environment variable, else the server `zig build pg-up` starts (`host=127.0.0.1 port=55432 user=zcube dbname=postgres`). `zig build pg-up` runs a throwaway Postgres 16 as the `postgres` user in `/tmp/zcube-pg` (override with `ZCUBE_PG_DIR`, `ZCUBE_PG_PORT`; `ZCUBE_PG_BIN` if the Postgres programs are not on PATH) and prints the variable; `zig build pg-down` stops it and deletes the directory; `zig build pg-stop` stops it and keeps the data (`pg-up` starts it again). The suite creates a schema of its own per test in that database and drops it, so any database it may create schemas in will do. `zig build test` also runs the Postgres-specific tests, and skips those that need a database when `ZCUBE_TEST_POSTGRES` is unset; `test-store -Dbackend=postgres` fails instead of skipping.
- `zig build wasm` compiles the control-plane core for `wasm32-freestanding` (`zig-out/wasm/zcube_core.wasm`); `zig build wasm-check [-Doptimize=ReleaseSafe]` runs it in Node (installed here at `/opt/node22`) and checks its result; `zig build wasm-test` runs the core's unit tests under WASI in Node. See `docs/wasm.md`.
- `zig build sim-c0 [-Dseed=N] [-Dops=N]` runs the deterministic C0 simulation natively and as WASM and compares the reports (a simulation, never reported as `demo-c0`); `zig build sim-c0-exe` installs its native runner for loops over many seeds. See `docs/core.md`.
- `zig build console-wasm` builds the console's browser module (`src/console_wasm.zig`, the real
  core over a memory store and the simulated runtime, ReleaseSafe) and checks it in Node under both
  V8 compilers: exactly one import (`env.zc_panic`), `GET /v1/status`, the C0 scenario, a reported
  panic. `zig build console-site` also installs the whole console to `zig-out/console` for any
  static file server. `node tools/browser_check.mjs <url> --mode sim|server` is the dev-time
  Playwright check. See `docs/console.md`.
- `zig build agent-smoke` starts `zcube-server` (SQLite) and one `zcube-agent` with `FakeRuntime` as real processes and checks them on the host: 3 replicas as 3 commands under 3 supervisors, a `kill -9` replaced, an agent restart with no duplicates, a server restart that changes nothing, an unknown digest held with `ZBX-E0501`. It kills everything it started, even on failure. **It is not `demo-c0`.** About 15 seconds. `docs/agent.md` describes the agent.
- `zcube-agent --node NAME --server HOST:PORT --state-dir DIR --cpu-millis N --memory-bytes N` runs the node agent (`--help` for the rest; a ZON file works too). Containers are plain host processes under supervisors of their own, so stopping the agent leaves them running and a restart adopts them. Test faults: write `oom`, `pid_limit` or `lost` into `<state-dir>/faults/<replica id>`.
- `zig build demo-c0 -Dbackend=sqlite|postgres [-Dtranscript=FILE]` runs HANDOFF's C0 demo for real: `zcube-server`,
  one `zcube-agent` with `FakeRuntime` and the `zcube` command as processes, every outcome asserted,
  a transcript printed (about 25-50 s). The Postgres run uses `-Dpostgres=` / `ZCUBE_TEST_POSTGRES` like `test-store`,
  owns that database's `zcube` schema (it drops it before and after), and stops and starts the database with
  `pg_dev stop` / `pg_dev up` (`zig build pg-stop`, `pg-up`) or with `ZCUBE_DEMO_PG_STOP` / `ZCUBE_DEMO_PG_START`.
  `docs/demos/c0.md` says what it asserts. Not `zig build sim-c0`, which is a simulation.
- `zig build check [-Dcheck-user=<user>|-]` runs every gate a slice must pass and ends in one line,
  `check: PASS <commit> (build test tidy errors-site wasm-check wasm-test console-wasm store:memory,sqlite sim-c0, test as tester)`
  or `check: FAIL <commit> (what failed)`. The gates are build-step dependencies; then
  `src/testing/check.zig` runs the Postgres suite (only when `ZCUBE_TEST_POSTGRES` is set), `sim-c0` with a
  fresh seed (printed as `sim-c0: seed N` first) and, as root, `zig build test` as `tester` in a scratch
  worktree of HEAD (`-Dcheck-user=-` skips it; `useradd -m tester` creates the user). `+dirty` after the commit
  means uncommitted changes the user run did not see. It leaves out `agent-smoke` and `demo-c0`.
- `zig build demo-cN` runs milestone N's demo.

## Working as the implementer

- Work in slices as the brief defines them (`docs/briefs/`). At the end of each slice, commit and stop with a report. The supervisor reviews each slice adversarially; what the review finds is fixed before the next slice, by a fresh session (see below).
- In a cloud session the container is ephemeral, so push each slice to your own session branch. Never push to `main`, and never to another session's branch.
- **Before you report, run [REVIEW.md](REVIEW.md) on your own diff**, and say which of its items your slice touched and what you checked.
- **Gates, on the commit you report:** `zig build check`; paste its last line (`check: PASS <commit>`, without `+dirty`). A report without that line, or with another commit's, is not a report. It does not run `agent-smoke` or `demo-c0` (CI does), nor the Postgres suite unless `ZCUBE_TEST_POSTGRES` is set: when the store changed, set it (`zig build pg-up` prints it) so the PASS line names `postgres`.
- Report what you ran and its output (the last lines, not the log), what you did not run and why, every deviation from HANDOFF or the brief, and anything in HANDOFF, DIAGNOSTICS or the Zigbox code that seemed wrong. End the report with the handoff note described below.

## Agent context discipline

An agent re-reads its whole context on every turn, so cost grows with context size, not with the work done. Keep implementer context small. (Adopted from Zigbox, 2026-10-30.)

- **One session per slice.** The supervisor starts a fresh implementer session for each slice of a milestone. Do not resume a finished implementer for the next slice or for follow-up fixes.
- **Hand off through the repo.** Before stopping, the implementer commits its work and ends its report with a handoff note: decisions made, traps found, what's next. Lasting decisions go in [docs/DECISIONS.md](docs/DECISIONS.md). The next implementer starts from the brief, the branch and that note.
- **Context ceiling.** Stop at about 250K tokens of context or 60 turns, whichever comes first. At that point, reach the next safe stopping place, commit, write the handoff note and report. The supervisor enforces this and starts a new implementer rather than extending the current one.
- **Small fixes get new sessions.** For a bug or review finding, start a fresh session with the symptom and the relevant commit. Do not send it back to the session that wrote the code.
- **Keep noisy output out of context.** Redirect `zig build` and test output to a file and read only the failing lines. Do not paste full logs.
- **Delegate lookups.** Send broad reads, such as searching the Zig std source or the pinned Zigbox package, to a cheap read-only agent and keep only the answer.
- The supervisor follows the same rules; its own handoff is [docs/supervisor-handoff.md](docs/supervisor-handoff.md).

## README and site status

- [README.md](README.md) holds the status of every milestone and slice: what is built and reviewed, what is in review, and what is not started. The supervisor updates it in the same push that changes the status. Never mark anything "demonstrated" until its `demo-cN` job is green in CI.
- The project site (`site/index.html`, the `SITE` and `MILESTONES` data at the top of its script) shows the same status. Update it in the same push as the README: the milestone's `status`, its `slices` count and, once a demo is green in CI, its `demo` lines taken from that run's recorded output, with `recorded` linking to the run (`{url, date}`), which renders the "recorded in CI" badge. Never show output that was not recorded as recorded. Pages deploys only from `main`.

## Git

- Develop on the branch you were given and commit in small, meaningful steps, signed off (`git commit -s`, DCO). Licence is Apache 2.0; there is no CLA.
- Never report an unpushed commit as pushed.
- CI runs only on pull requests and on `main`, never on a plain branch push. When a change needs CI, open a PR (or push to an open one); don't push just to trigger CI, and batch small follow-ups into one push. Actions time is limited.
- A change that touches only documentation (every changed path is a `.md` file outside `web/` and `src/`, or lies under `site/` outside `site/errors/`) skips CI's jobs, as the `changes` job in `ci.yml` decides. That does not change when a commit may carry `[skip ci]`.
- A commit that only records status (README.md and `site/index.html` updated after a CI result) carries `[skip ci]` in its message, so it does not start a run of its own. Never use `[skip ci]` on a commit that changes code, tests, CI or generated files.
