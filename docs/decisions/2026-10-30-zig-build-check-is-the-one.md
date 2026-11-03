# zig build check is the one gate command (ported from Zigbox's): cheap gates as build-step dependencies, then src/testing/check.zig runs Postgres (when ZCUBE_TEST_POSTGRES is set), sim-c0 with a fresh seed and, as root, zig build test as tester; it ends in check: PASS <commit> (...)

*Decided 2026-10-30.*

`zig build check` is the one gate command (ported from Zigbox's): cheap gates as build-step dependencies, then `src/testing/check.zig` runs Postgres (when `ZCUBE_TEST_POSTGRES` is set), `sim-c0` with a fresh seed and, as root, `zig build test` as `tester`; it ends in `check: PASS <commit> (...)`. `agent-smoke` and `demo-c0` stay CI-only.

Where: `docs/briefs/c1-1.md`, `AGENTS.md`
