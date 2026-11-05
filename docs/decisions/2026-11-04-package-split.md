# Packages: one dev omnibus, and one package per role on Linux (owner, 2026-11-04)

*Decided 2026-11-04, by the owner.*

Refines `2026-11-04-linux-packages.md`. A dev wants one install that does everything; an operator
installs one role per host.

- **macOS:** one package with everything. `zcube` joins `zbx` in the Homebrew `zigbox` formula.
- **Linux:** `zigbox`, the dev omnibus (`zbx`, `zcube`, `zcube-server`, `zcube-agent`), and
  `zigcube-cli`, `zigcube-server` and `zigcube-agent`, one per role. Any of them may carry `zbx`
  where it helps: `zigcube-agent` does, for `zbx doctor` and debugging, though the agent links the
  `zigbox` module and never runs `zbx`.
- Zigbox's M8 builds the package writer and ships `zigbox` with `zbx` alone; C3 widens it and adds
  the three `zigcube-*` packages. The packages and the signed macOS `zcube` are part of C3.

Detail: `docs/briefs/c3-linux-packages.md`, `docs/briefs/c3-macos-cli.md`; Zigbox
`docs/briefs/linux-packages.md`.
