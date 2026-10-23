# Zigcube

An orchestrator for Zigbox workloads: store-aware scheduling, peer chunk distribution, trust checked on every node, and grant-based networking.

**Status:** pre-alpha, planning. Nothing here runs yet.

## Layout

- `site/` — the project website (`index.html`), deployed to GitHub Pages by `.github/workflows/pages.yml`.
- Code arrives with the first milestone.

## Updating the site

Milestone status, demo output and docs entries live in the `SITE`, `MILESTONES` and `DOCS` objects at the top of the script in `site/index.html`. Set a milestone's `status` to `"wip"` or `"done"` and replace its `demo` lines with real recorded output when it ships.

## Licence

Apache 2.0, with a standing pledge never to relicense. Contributions are accepted under a [Developer Certificate of Origin](https://developercertificate.org/) sign-off (`git commit -s`); there is no CLA.
