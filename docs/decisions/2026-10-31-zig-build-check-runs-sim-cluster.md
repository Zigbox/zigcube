# zig build check runs sim-cluster (fresh seed, 40 operations, Debug so the WASM core built by wasm-check is reused) and sim-teeth; the PASS line names both.

*Decided 2026-10-31.*

`zig build check` runs `sim-cluster` (fresh seed, 40 operations, Debug so the WASM core built by `wasm-check` is reused) and `sim-teeth`; the PASS line names both.

Where: `src/testing/check.zig`, `AGENTS.md`
