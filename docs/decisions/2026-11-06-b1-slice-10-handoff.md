# B1 slice 10 handoff: demo-b1

`zig build demo-b1 -Dbackend=sqlite|postgres` and `docs/demos/b1.md`. Not marked demonstrated:
the supervisor does that once both `demo-b1` CI jobs are green.

- **Files.** `src/demo_b1.zig` (main, cleanup), `demo_b1_state.zig` (bounds, `GET /v1/jobs/<name>`
  reads), `demo_b1_fleet.zig` (two nodes; `kill_agent`, `fault`), `demo_b1_endings.zig` (steps 1
  and 2), `demo_b1_nodes.zig` (3 and 4), `demo_b1_packing.zig` (5). CI: `ci.yml` jobs
  `demo-b1-sqlite`/`-postgres`, rule `src/demo_b1*.zig` in `.github/ci-changes.sh`, a new column
  and two rows in `ci-changes-test.sh`.
- **Cut:** `job logs` (slice 8 is cut). **Deviation:** step 5 posts jobs with `limits` over HTTP
  because the CLI has no cpu flag. Both are in `docs/demos/b1.md`.
- **Traps.** `host.now_ms()` is not the epoch: use the real clock for `submit_by_ms`. The CLI's
  `--command` takes the rest of the line. The fake runtime's fault file is `<job>-job`, and must be
  written after the job runs. The watcher is a separate process whose output is a file.
- **Not run here:** the full CI matrix. Next: after green CI, the supervisor updates README and site.
