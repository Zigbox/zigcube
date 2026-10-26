# Zigcube: operating instructions

Zigcube is the orchestrator for Zigbox workloads, written in Zig. The coding handoff for C0 and C1 is [HANDOFF.md](HANDOFF.md); the wider design is Part II of Zigbox's `docs/SPEC.md` (repo `Zigbox/zigbox`), a snapshot of the live design doc (https://claude.ai/artifact/6D9js8mxSLYmfuZe3rQ26w). If they disagree, the live doc wins: stop and report the conflict rather than picking one.

## Rules

- **Read [HANDOFF.md](HANDOFF.md) and [DIAGNOSTICS.md](DIAGNOSTICS.md) before writing code.** HANDOFF's **Ask first** list binds you. Every failure path follows DIAGNOSTICS.md, which is shared with Zigbox: change both copies together, and treat Zigbox's as canonical.
- **Style and testing follow [docs/STYLE.md](docs/STYLE.md)** (Zigbox's TigerStyle rules, with Zigcube's departures at the top). Review rejects code that breaks it.
- Work one milestone at a time. Do not start a later milestone or build anything HANDOFF puts out of scope.
- A milestone is done only when its demo script passes start to finish on a clean machine. Unit tests passing, or code that compiles, is never reported as a passed demo. Say exactly what was and was not run.
- Each demo script becomes an automated test, `zig build demo-cN`. Never break an earlier demo: all prior `demo-cN` tests and the store conformance suite run in CI.
- When scope is in doubt, cut scope and keep the demo. Record the cut in the milestone's demo document, `docs/demos/cN.md`.
- Zig version is pinned in `build.zig.zon` (`minimum_zig_version`) and CI, matching Zigbox. Do not upgrade during a milestone.
- The pinned Zig is newer than most model training data, and std APIs (I/O, `std.Io`, readers and writers, the build system) changed in 0.15–0.17. `@cImport` is gone: C headers go through `b.addTranslateC`. Read the pinned std source (`zig env` prints ZON, and its `.lib_dir` field names the directory; `std` is under it) before using an API. Do not write from memory.
- The agent links Zigbox's `zigbox` module. Zigcube's `Runtime` interface follows what that module actually exposes. Report any gap between it and HANDOFF to the owner; don't paper over it.

## Environment facts (checked 2026-10-25 in the Claude Code cloud container)

- `.claude/hooks/session-start.sh` installs Zig 0.17.0 (checksum-verified) and libpq-dev, and puts `zig` and the Postgres 16 binaries on PATH.
- Postgres 16 is installed without the OrioleDB extension, so the plain-heap schema path is what runs here. `initdb` refuses root: run it as `postgres` in a directory that user owns, e.g. `su postgres -c "initdb -D $DIR -A trust -U zcube"`.
- SQLite 3 headers and the library are present.
- Zig downloads from https://ziglang.org/download/ work through the proxy.

## Commands

These arrive with the scaffold; keep this list current as they land.

- `zig build` builds `zig-out/bin/zcube`, `zcube-server` and `zcube-agent`.
- `zig build test` runs unit and snapshot tests (tidy's own tests included).
- `zig build tidy` checks formatting and the mechanical style rules: 100 columns, 70-line functions, banned patterns, `catch unreachable` comments, no `and`/`or` inside `assert(...)`. Run it before every commit; CI does.
- `zig build test-store -Dbackend=memory|sqlite|postgres [-Dseed=N]` runs the store conformance suite. It always re-runs with a fresh seed (Zig's per-run test seed), prints nothing when it passes, and a failing test prints `seed=N`; replay with `-Dseed=N`. SQLite needs `libsqlite3-dev`, Postgres `libpq-dev` (the session-start hook installs it).
- **The Postgres test database.** `-Dbackend=postgres` takes the connection from `-Dpostgres=<libpq settings>`, else the `ZCUBE_TEST_POSTGRES` environment variable, else the server `zig build pg-up` starts (`host=127.0.0.1 port=55432 user=zcube dbname=postgres`). `zig build pg-up` runs a throwaway Postgres 16 as the `postgres` user in `/tmp/zcube-pg` (override with `ZCUBE_PG_DIR`, `ZCUBE_PG_PORT`; `ZCUBE_PG_BIN` if the Postgres programs are not on PATH) and prints the variable; `zig build pg-down` stops it and deletes the directory. The suite creates a schema of its own per test in that database and drops it, so any database it may create schemas in will do. `zig build test` also runs the Postgres-specific tests, and skips those that need a database when `ZCUBE_TEST_POSTGRES` is unset; `test-store -Dbackend=postgres` fails instead of skipping.
- `zig build demo-cN` runs milestone N's demo.

## Working as the implementer

- Work in slices. At the end of each slice, commit and stop with a report. The supervisor reviews each slice adversarially, and you fix what the review finds before the next slice.
- In a cloud session the container is ephemeral, so push each reviewed slice to your own branch. Never push to `main`.
- Report what you ran and its output, what you did not run and why, every deviation from HANDOFF, and anything in HANDOFF, DIAGNOSTICS or the Zigbox code that seemed wrong.

## README and site status

- [README.md](README.md) holds the status of every milestone and slice: what is built and reviewed, what is in review, and what is not started. The supervisor updates it in the same push that changes the status. Never mark anything "demonstrated" until its `demo-cN` job is green in CI.
- The project site (`site/index.html`, the `SITE` and `MILESTONES` data at the top of its script) shows the same status. Update it in the same push as the README: the milestone's `status`, its `slices` count and, once a demo is green in CI, its `demo` lines taken from that run's recorded output, with `recorded` linking to the run (`{url, date}`), which renders the "recorded in CI" badge. Never show output that was not recorded as recorded. Pages deploys only from `main`.

## Git

- Develop on the branch you were given and commit in small, meaningful steps, signed off (`git commit -s`, DCO). Licence is Apache 2.0; there is no CLA.
- Never report an unpushed commit as pushed.
- CI runs only on pull requests and on `main`, never on a plain branch push. When a change needs CI, open a PR (or push to an open one); don't push just to trigger CI, and batch small follow-ups into one push. Actions time is limited.
- A commit that only records status (README.md and `site/index.html` updated after a CI result) carries `[skip ci]` in its message, so it does not start a run of its own. Never use `[skip ci]` on a commit that changes code, tests, CI or generated files.
