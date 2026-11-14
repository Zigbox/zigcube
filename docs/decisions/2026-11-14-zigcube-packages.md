# Zigcube's packages: layout, key, site, tap

*Proposed 2026-11-14 by the packaging slice. Becomes a decision when the owner answers the
questions marked ASK in `docs/briefs/packaging.md`; this file is then edited once, before it
merges, and never after.*

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
- **Packages:** `zigcube-cli`, `zigcube-server`, `zigcube-agent`, `zigcube`; names, contents and
  dependencies as in the brief's table. `zigcube-agent` depends on `zigbox (>= 0.5.0)`.
- **Mac:** `zcube` only, a universal zip, a separate formula `zigcube` in `Zigbox/homebrew-tap`,
  written by Zigcube's release and by nothing else.
- **Server baseline:** built on a RHEL 9 compatible image (glibc 2.34), one binary per architecture
  for all four distributions, until a test shows a distribution refuses it.
- **Release order:** Zigbox's release is published before Zigcube's, because Zigcube's `verify`
  installs `zigbox` from zigbox.org.

## Why

A shared suite would make every release re-sign the other product's file and change Zigbox's
workflows. A second suite gives users one source and one key and leaves Zigbox untouched. The
numbers behind the server's baseline (static `zcube`, `zcube-agent`; dynamic `zcube-server`; the
failed cross build) are in the brief.

Where: `docs/briefs/packaging.md`; later `docs/releases/automation.md` and `packaging.md`.
