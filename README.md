# Zigcube

An orchestrator for Zigbox workloads: store-aware scheduling, peer chunk distribution, trust checked on every node, and grant-based networking.

- **Coding handoff (C0, C1):** [HANDOFF.md](HANDOFF.md).
- **How the code is written and tested:** [docs/STYLE.md](docs/STYLE.md) (Zigbox's TigerStyle rules, with Zigcube's departures).
- **Diagnostics standard, shared with Zigbox:** [DIAGNOSTICS.md](DIAGNOSTICS.md).
- **Rules for contributors and agents:** [AGENTS.md](AGENTS.md).
- **Web console (design and clickable prototype):** [docs/console.md](docs/console.md), with the HTTP API it needs proposed in [docs/api.md](docs/api.md).

## Status

*As of 2026-10-27. Pre-alpha. **C0 is demonstrated**: `demo-c0` is green in CI on Postgres and SQLite ([run 40556942364](https://github.com/Zigbox/zigcube/actions/runs/40556942364), on `main` at the merge of [PR #15](https://github.com/Zigbox/zigcube/pull/15)). Everything runs against `FakeRuntime` (plain host processes), not real Zigbox, and on one node. How it fits together: [the architecture page](site/architecture.html), published at https://zigbox.github.io/zigcube/architecture.html.*

| Milestone | What it adds | Status |
| --- | --- | --- |
| C0 · Loop | One node keeps a promise: apply, get, why | **Demonstrated** 2026-10-27, [CI run](https://github.com/Zigbox/zigcube/actions/runs/40556942364) |
| C1 · Fleet | Placement across nodes, failover on lease expiry | Not started (next) |
| C2–C8 | Swarm, Rollout, Mesh, Edge, Trust, State, Jobs | Not started |

A milestone is marked **demonstrated** only when its `demo-cN` job is green in CI, with a link to that run.

### C0 in detail

C0 was built in nine slices, each reviewed adversarially before it was merged. [docs/demos/c0.md](docs/demos/c0.md) says what the demo asserts, and what it cuts and does not cover.

| Slice | Contents | Status |
| --- | --- | --- |
| 1 · Scaffold and contracts | Zig 0.17.0 pinned, CI, the `ZC-` registry, the approved `Store` and `Runtime` contracts, the memory store | Merged, [PR #4](https://github.com/Zigbox/zigcube/pull/4) |
| 2 · SQLite and conformance | `zig build tidy`, the SQLite backend, the store conformance suite | Merged, [PR #5](https://github.com/Zigbox/zigcube/pull/5) |
| 3 · Postgres | The Postgres backend (revisions serialised on the meta row, `LISTEN`/`NOTIFY` with a bounded poll), `pg-up`/`pg-down`, a CI job on Postgres 16 | Merged, [PR #7](https://github.com/Zigbox/zigcube/pull/7) |
| 4 · Contracts and WASM | Contract additions, Zigbox's diagnostics through the pinned `zigbox` package, the core on `wasm32-freestanding` | Merged, [PR #9](https://github.com/Zigbox/zigcube/pull/9) |
| 5a · Core | Controllers as steps, decision records, `why`, retention, the simulated runtime, `sim-c0` (native against WASM) | Merged, [PR #11](https://github.com/Zigbox/zigcube/pull/11) |
| 5b · Server | `zcube-server`, the write endpoints, the console on the real core in WASM | Merged, [PR #12](https://github.com/Zigbox/zigcube/pull/12) |
| 6a · Agent | `zcube-agent`, `FakeRuntime` with a supervisor per container, the agent endpoints, `agent-smoke` | Merged, [PR #14](https://github.com/Zigbox/zigcube/pull/14) |
| 6b · CLI | `zcube`, bundles, golden tests for every code, the no-stack-trace check, error pages | Merged, [PR #13](https://github.com/Zigbox/zigcube/pull/13) |
| 6c · Demo | `demo-c0` on Postgres and SQLite, and the two defects it found | Merged, [PR #15](https://github.com/Zigbox/zigcube/pull/15); **green in CI** |

Not run yet: OrioleDB, real Zigbox, more than one node.

## Building

Requires Zig 0.17.0 exactly ([download](https://ziglang.org/download/)), and the SQLite 3 and libpq development files (`libsqlite3-dev`, `libpq-dev`) to run the tests.

```sh
zig build                                   # zig-out/bin/zcube, zcube-server, zcube-agent
zig build test                              # unit and snapshot tests
zig build tidy                              # formatting and mechanical style rules
zig build test-store -Dbackend=sqlite       # the store conformance suite (memory | sqlite | postgres)
zig build wasm-check                        # the core as wasm32-freestanding, run in Node (needs node)
zig build wasm-test                         # the core's unit tests under WASI in Node
zig build pg-up                             # a throwaway Postgres for -Dbackend=postgres (pg-down removes it)
zig build demo-c0 -Dbackend=sqlite          # the C0 demo: real server, agent and CLI processes (or postgres)
```

The conformance suite draws a new random seed on every run. A failing test prints it; `-Dseed=N` replays that run.

## Layout

- `site/` — the project website (`index.html`, `architecture.html`, generated `errors/`), deployed to GitHub Pages by `.github/workflows/pages.yml`.
- `web/` — the web console: static files, no build step, no external requests. `python3 -m http.server -d web`, then open `/?mock=c0` (or `c1`) to click through it against the in-browser mock.
- `src/` — the three executables, the core (listed in `src/core.zig`) and the shell around it.

## Updating the site

Milestone status, demo output and docs entries live in the `SITE`, `MILESTONES` and `DOCS` objects at the top of the script in `site/index.html`. Set a milestone's `status` to `"wip"` when work starts. When it ships, set `"done"`, record its `slices` count, replace its `demo` lines with output recorded by the green `demo-cN` CI run, and set `recorded: {url, date}` to that run, which shows the "recorded in CI" badge. Update this README's status table in the same push.

## Licence

Apache 2.0, with a standing pledge never to relicense. Contributions are accepted under a [Developer Certificate of Origin](https://developercertificate.org/) sign-off (`git commit -s`); there is no CLA.
