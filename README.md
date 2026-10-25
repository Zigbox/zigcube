# Zigcube

An orchestrator for Zigbox workloads: store-aware scheduling, peer chunk distribution, trust checked on every node, and grant-based networking.

- **Coding handoff (C0, C1):** [HANDOFF.md](HANDOFF.md).
- **How the code is written and tested:** [docs/STYLE.md](docs/STYLE.md) (Zigbox's TigerStyle rules, with Zigcube's departures).
- **Diagnostics standard, shared with Zigbox:** [DIAGNOSTICS.md](DIAGNOSTICS.md).
- **Rules for contributors and agents:** [AGENTS.md](AGENTS.md).

## Status

*As of 2026-10-25. Pre-alpha: C0 is about to start against a fake runtime. Nothing here runs yet.*

| Milestone | What it adds | Status |
| --- | --- | --- |
| C0 · Loop | One node keeps a promise: apply, get, why | Not started |
| C1 · Fleet | Placement across nodes, failover on lease expiry | Not started |
| C2–C8 | Swarm, Rollout, Mesh, Edge, Trust, State, Jobs | Not started |

A milestone is marked **demonstrated** only when its `demo-cN` job is green in CI, with a link to that run.

## Layout

- `site/` — the project website (`index.html`), deployed to GitHub Pages by `.github/workflows/pages.yml`.
- Code arrives with the first milestone.

## Updating the site

Milestone status, demo output and docs entries live in the `SITE`, `MILESTONES` and `DOCS` objects at the top of the script in `site/index.html`. Set a milestone's `status` to `"wip"` when work starts. When it ships, set `"done"`, record its `slices` count, replace its `demo` lines with output recorded by the green `demo-cN` CI run, and set `recorded: {url, date}` to that run, which shows the "recorded in CI" badge. Update this README's status table in the same push.

## Licence

Apache 2.0, with a standing pledge never to relicense. Contributions are accepted under a [Developer Certificate of Origin](https://developercertificate.org/) sign-off (`git commit -s`); there is no CLA.
