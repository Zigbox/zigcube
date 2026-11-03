# sim_cluster takes --seeds A..B, prints a line and a replay command per failing seed, and --shrink bisects ops with the heal point held fixed (Options.heal_at, printed as --heal-at=H), counting a candidate as failing only if it fails with the same symptom: a short run can fail the work floor instead, which is another bug

*Decided 2026-10-31.*

`sim_cluster` takes `--seeds A..B`, prints a line and a replay command per failing seed, and `--shrink` bisects `ops` with the heal point held fixed (`Options.heal_at`, printed as `--heal-at=H`), counting a candidate as failing only if it fails with the same symptom: a short run can fail the work floor instead, which is another bug. `enough_work_under_faults` is given `min(H, ops)` so a held `H` beyond a short run does not demand work it had no time for.

Where: `src/sim_cluster.zig`, `src/sim_cluster_main.zig`
