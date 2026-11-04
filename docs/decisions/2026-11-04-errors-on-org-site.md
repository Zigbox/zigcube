# Zigcube's error pages move to zigbox.org/errors/cube/

*Decided 2026-11-04, by the owner (one site for `zigbox.org`, errors under `/box` and `/cube`) and the supervisor (the layout).*

Zigbox's `docs/decisions/2026-11-04-project-domain-zigbox-org.md` left Zigcube's error address to a Zigcube decision; Zigbox's `2026-11-04-errors-on-org-site.md` put `zigbox.org` on the organisation site, `Zigbox/zigbox.github.io`. This is that Zigcube decision. The earlier proposal of `cube.zigbox.org` is dropped.

## Decision

| What | Today | From now on |
|---|---|---|
| Error pages (`docs_url_base`, `src/diag.zig`) | `https://zigbox.github.io/zigcube/errors/` | `https://zigbox.org/errors/cube/` |
| Zigcube's status site and console demo | `https://zigbox.github.io/zigcube/` | `https://zigbox.org/zigcube/` (still `site/` here, served by this repository's Pages) |

The pages are still generated here (`zig build errors-site`, checked by `errors-site-check`) into `site/errors/`. The organisation site's Pages workflow copies `site/errors/*.html` from `main` into `/errors/cube/`. Zigcube's links to Zigbox pages follow whatever the pinned Zigbox prints.

## Rules

- `docs_url_base` is the only place the address is spelled out; the move changes it, regenerates `site/errors/` and the goldens from it, and hand-edits neither.
- This repository keeps publishing `site/errors/` in its own Pages site, so the old address keeps working through GitHub's 301 from `zigbox.github.io/zigcube/...` to `zigbox.org/zigcube/...`. `Zigbox/zigcube` must not get a custom domain of its own.
- The move is mechanical (a Haiku session) and lands after 0.3.1 is pinned and C2 has shipped, so it does not disturb the C2 release. It does not merge until `curl -sI https://zigbox.github.io/zigcube/errors/E0101.html` returns a 301 to `https://zigbox.org/zigcube/errors/E0101.html` and `https://zigbox.org/errors/cube/E0101.html` returns 200.
