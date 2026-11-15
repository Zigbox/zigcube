# C3 slice 9: the cluster simulation's health world

*Decided 2026-11-14, by the review fixes of C3 slice 9 (the review's SHOULD).*

- **A draw-free world, `--health` (`Options.health`).** Services `alpha` and `gamma` get a health
  check (`check --quiet`, every 5 s, timeout 1 s, 2 failures, 1 pass), and every runtime fault
  also scripts how the checks of one running container on the faulted node come out, in turn:
  fail, hang, pass, refused at poll, refused at begin (`SimRuntime.script_health`, which counts
  round the running containers and draws nothing). Off, a run is the world it was before.
- **On in the `sim-c1` build step, so in `zig build check`** (`-Dc1-health=false` leaves it out),
  native against WASM (`zcube_sim_cluster_shaped` takes a `health` argument; `wasm_check.mjs`
  passes it when `--health` follows the native report). **Off in `auto` runs and the fleet:**
  turning it on there changes every fleet world and every canary; that is the supervisor's call.
- **No tooth.** None of the brief's checks (R1 to R8) is about health before the rollout slices,
  so there is no check for a tooth to fail. The world's report line, `health: on; scripted=..
  checks begun=.. refused at begin=..`, shows the seam ran.
- **A 5 s interval, not 1 s.** At 1 s, seven of seeds 1 to 40 (`auto`) failed the busy-loop
  check: each due check and each poll is a whole agent step (heartbeat, listing, store reads).
  That is the slice's design, reported to the supervisor, not changed here.

The world found one bug on its first seed: `probe_scheduler.poll_at` asserted that the check
began no later than the agent's step began, but a check begins later in the same step;
`wake_ms` now polls from whichever is later.

Where: `src/sim_cluster.zig` (`sim_health`, `health_scripts`, `script_health`),
`src/sim_runtime.zig` (`HealthScript.refuses_to_begin`, `script_health`), `build.zig`
(`c1_health`), `src/wasm_core.zig`, `tools/wasm_check.mjs`.
