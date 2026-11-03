# C1 slice 7.6: zcube local up|down (src/cli_local.zig, shell code, the one zcube command that starts processes)

*Decided 2026-11-03.*

C1 slice 7.6: `zcube local up|down` (`src/cli_local.zig`, shell code, the one `zcube` command that starts processes). Server and agent are found beside the `zcube` executable (`Env.bin_dir` overrides it in tests) and spawned in their own process group, so they outlive `zcube`. `up` and `down` hold a `flock` on `<dir>/lock` (`ZC-E0124` after 60 s). A pid file (`<pid> <start time>`) counts only if the process is no zombie, has that start time, and its `cmdline` is exactly ours (`--store sqlite:<dir>/zcube.db`, or `--state-dir <dir>/agent`, never `supervise`); otherwise it is stale and deleted, never signalled. Readiness is the new agent log's `registered` line plus the node in the store (re-registering does not move the revision). `setsid` is not offered by `std.process.spawn`; the processes get a group of their own (`pgid = 0`). Port 7070 or the next free one, preferring the last one used. `images.zon` is written from an embedded copy of `fixtures/images.zon` (a test keeps them equal). An unusable local directory reuses `ZC-E0116`, whose text now covers `ZCUBE_LOCAL_DIR`. New: `ZC-E0122` (executable missing), `ZC-E0123` (did not come up).

Where: `src/cli_local.zig`, `docs/cli.md`
