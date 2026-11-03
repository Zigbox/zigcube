# sim-cluster liveness mode (C1 slice 2b part F)

*Decided 2026-10-31.*

sim-cluster liveness mode (C1 slice 2b part F). It is the default and `-Dliveness=false` is a safety-only run. On: the faults run for the first `H` operations, `H` drawn from the seed alone in [ops/2, ops]; at `H` every fault is off (store up, loss zero, links healed and the fault operations get no weight) and the remaining operations are fault-free workload; `liveness_bound_ms` = 240 s after the last operation the end state must have every service at its replicas and no stray container. The bound is a constant in `sim_cluster.zig` and the report prints it with `H`. Before this the heal was always after the last operation with the same 240 s, so the old run was a liveness run with `H` = ops; the seed-chosen `H` also tests workload changes on a healed world. Off: faults stay on to the end, no convergence check, the per-second and per-step checks, the work floor and ceiling still apply. The report says plainly that the duplicates count is "counted, NOT a pass" until slice 6. Native and WASM agree on the report byte for byte (`zig build sim-cluster`); the WASM library's stack is 8 MiB because the cluster nests deeper than the 1 MiB default (2 MiB traps, 4 MiB passes).

Where: `src/sim_cluster.zig`, `build.zig`, `tools/wasm_check.mjs`
