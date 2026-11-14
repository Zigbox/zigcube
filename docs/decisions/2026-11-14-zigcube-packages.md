# Zigcube's packages: layout, key, site, tap

*Decided 2026-11-14, by the supervisor (layout, key, site, formula, name collision, the `ZC-`
code for a store not built in) and the owner (package list, Mac dependency).*

## The contract

- **One site, one key, two suites.** `https://zigbox.org/apt` carries suite `stable` (Zigbox) and
  suite `zigcube`; `https://zigbox.org/rpm/` carries Zigbox's `$basearch` trees and `zigcube/$basearch`.
  Each product signs and re-dates only its own suite. Supersedes nothing; it extends
  `Zigbox/zigbox` `docs/decisions/2026-11-10-packages-on-zigbox-org.md`, whose "one asset" becomes
  "one asset per product".
- **Paths owned by Zigcube's asset `zigcube-repos.tar.gz`:** `apt/dists/zigcube/**`,
  `apt/pool/main/z/zigcube*/**`, `rpm/zigcube/**`. The asset holds no keyring, no dot file, no
  `.html`, nothing else. Zigbox's asset keeps its paths; the two never share one.
- **Release `Suite` and `Codename` are `zigcube`; `Origin` is `Zigbox`.** `Valid-Until` is 21 days after
  signing, as Zigbox's; Zigcube's own weekly refresh re-dates its suite.
- **Key.** The Zigbox release key (primary `09991DC39816D3C914E2A22C5AB00BC328B7DBB7`); Zigcube's
  workflows pin that fingerprint and check every signature is by a subkey of it, against a public
  key checked in to Zigcube, never against a keyring inside an asset. The keyring users fetch
  stays `https://zigbox.org/zigbox-archive-keyring.gpg`.
- **Packages (owner, 2026-11-14; Linux only):** `zigbox` (`zbx`; Zigbox's own package from suite `stable`, never built by
  Zigcube), `zigcube` (`zcube`, no dependencies), `zigcube-server-sqlite` and
  `zigcube-server-postgres` (one store each plus memory; both install `/usr/bin/zcube-server`, each
  `Conflicts` with and `Replaces` the other, both `Provide` `zigcube-server`; each depends on
  `zigcube` and its library), `zigcube-agent` (depends on `zigcube`, `Recommends` `zigbox`: the agent
  never runs `zbx`), `zigbox-dev` (no files; depends on `zigbox (>= pinned version)`,
  `zigcube-server-sqlite`, `zigcube-agent`). Installing starts nothing: units ship disabled.
  A build option `-Dstore=sqlite|postgres|all` (default `all`) makes the two server builds; a
  `--store` for a backend not built in is refused in one line (a `ZC-` code, approved).
- **Mac (owner, 2026-11-14):** formulas for `zbx` and `zcube` only; the `zigcube` formula in
  `Zigbox/homebrew-tap` (a universal zip, written by Zigcube's release and by nothing else)
  `depends_on "zigbox/tap/zigbox"`, since the server and agent run in the zbx VM there.
- **Server baseline:** each server flavour built on a RHEL 9 compatible image (glibc 2.34), one binary per
  architecture and flavour for all four distributions, until a test shows a distribution refuses it.
- **Release order:** Zigbox's release is published before Zigcube's, because Zigcube's `verify`
  installs `zigbox` from zigbox.org.

## Why

A shared suite would make every release re-sign the other product's file and change Zigbox's
workflows. A second suite gives users one source and one key and leaves Zigbox untouched. The
numbers behind the server's baseline (static `zcube`, `zcube-agent`; dynamic `zcube-server`; the
failed cross build) are in the brief.

Where: `docs/briefs/packaging.md`; later `docs/releases/automation.md` and `packaging.md`.
