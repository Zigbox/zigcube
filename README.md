# Zigcube

An orchestrator for Zigbox workloads: store-aware scheduling, peer chunk distribution, trust checked on every node, and grant-based networking.

- **Coding handoff (C0, C1):** [HANDOFF.md](HANDOFF.md).
- **How the code is written and tested:** [docs/STYLE.md](docs/STYLE.md) (Zigbox's TigerStyle rules, with Zigcube's departures).
- **Diagnostics standard, shared with Zigbox:** [DIAGNOSTICS.md](DIAGNOSTICS.md).
- **Rules for contributors and agents:** [AGENTS.md](AGENTS.md).
- **Web console (design and clickable prototype):** [docs/console.md](docs/console.md), with the HTTP API it needs proposed in [docs/api.md](docs/api.md).

## Status

*As of 2026-10-26. Pre-alpha: C0 is under way against a fake runtime. There is no server, agent or CLI command yet; what exists is the storage layer, below. Nothing is demonstrated.*

| Milestone | What it adds | Status |
| --- | --- | --- |
| C0 · Loop | One node keeps a promise: apply, get, why | **In progress**: slices 1 to 4 below |
| C1 · Fleet | Placement across nodes, failover on lease expiry | Not started |
| C2–C8 | Swarm, Rollout, Mesh, Edge, Trust, State, Jobs | Not started |

A milestone is marked **demonstrated** only when its `demo-cN` job is green in CI, with a link to that run.

### C0 in detail

C0 is built in slices. Each is reviewed adversarially before it is merged. A slice is not a demo: `demo-c0` is not written yet.

| Slice | Contents | Status |
| --- | --- | --- |
| 1 · Scaffold and contracts | Zig 0.17.0 pinned; three stub executables; CI; limits in `src/constants.zig`; the `ZC-` diagnostics registry and `Diag` collector; the `Store` and `Runtime` contracts (both approved 2026-10-26); an in-memory reference store; the [review pack](docs/contracts-review.md) and [store design](docs/store-design.md) | **Built and reviewed**, in [PR #4](https://github.com/Zigbox/zigcube/pull/4) |
| 2 · SQLite and conformance | `zig build tidy`; the SQLite `Store` backend (WAL, serialised writers, gap-free revisions, polling watch, leases on the injected clock, failures as `ZC-E02xx` diagnostics); the store conformance suite (`zig build test-store`), run for the memory and SQLite backends; the [proposal for Zigbox's diagnostics](docs/diagnostics-zigbox-proposal.md) | **In review.** Not yet run in CI. |
| 3 · Postgres | The Postgres backend (revisions serialised on the meta row, `LISTEN`/`NOTIFY` wake-ups with a bounded poll, a watch that checks the log has no hole, leases on Postgres's clock or an injected one, `store_live` on OrioleDB when present), libpq through `b.addTranslateC`, failures as `ZC-E02xx` diagnostics (new: E0211 to E0213), run through the same suite; `zig build pg-up`/`pg-down` for a throwaway server; a CI job against a pinned Postgres 16 image | **In review.** Not yet run in CI; the OrioleDB path has not been run. |
| 4 · Contracts and WASM | `Store.list` with `reverse` and a read-only `Store.lease_list`, in all three backends with conformance tests; the record shapes of the approved console items in [keys.md](docs/keys.md); Zigcube's diagnostics on Zigbox's `diagnostic`/`product`/`render`/`explain` (the `zigbox` package, pinned) with the stand-in retired; three comment-only `Runtime` doc tweaks; the control-plane core compiled to `wasm32-freestanding` and run in Node (`zig build wasm-check`, `wasm-test`) in a new CI job, and [what that found](docs/wasm.md) | **In review.** Not yet run in CI: the `zigbox` tarball URL, Node on the runner and the `wasm` job are first exercised there. |

## Building

Requires Zig 0.17.0 exactly ([download](https://ziglang.org/download/)), and the SQLite 3 and libpq development files (`libsqlite3-dev`, `libpq-dev`) to run the tests.

```sh
zig build                                   # zig-out/bin/zcube, zcube-server, zcube-agent (stubs)
zig build test                              # unit and snapshot tests
zig build tidy                              # formatting and mechanical style rules
zig build test-store -Dbackend=sqlite       # the store conformance suite (memory | sqlite | postgres)
zig build wasm-check                        # the core as wasm32-freestanding, run in Node (needs node)
zig build wasm-test                         # the core's unit tests under WASI in Node
zig build pg-up                             # a throwaway Postgres for -Dbackend=postgres (pg-down removes it)
```

The conformance suite draws a new random seed on every run. A failing test prints it; `-Dseed=N` replays that run.

## Layout

- `site/` — the project website (`index.html`), deployed to GitHub Pages by `.github/workflows/pages.yml`.
- `web/` — the web console: static files, no build step, no external requests. `python3 -m http.server -d web`, then open `/?mock=c0` (or `c1`) to click through it against the in-browser mock.
- Server and agent code arrives with the first milestone.

## Updating the site

Milestone status, demo output and docs entries live in the `SITE`, `MILESTONES` and `DOCS` objects at the top of the script in `site/index.html`. Set a milestone's `status` to `"wip"` when work starts. When it ships, set `"done"`, record its `slices` count, replace its `demo` lines with output recorded by the green `demo-cN` CI run, and set `recorded: {url, date}` to that run, which shows the "recorded in CI" badge. Update this README's status table in the same push.

## Licence

Apache 2.0, with a standing pledge never to relicense. Contributions are accepted under a [Developer Certificate of Origin](https://developercertificate.org/) sign-off (`git commit -s`); there is no CLA.
