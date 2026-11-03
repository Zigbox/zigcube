# C1 slice 7: completeness is always emitted by why (complete, or truncated with at and reason in retention, subject_deleted, compacted); a chain ending in a gone step is truncated

*Decided 2026-11-02.*

C1 slice 7: `completeness` is always emitted by `why` (`complete`, or `truncated` with `at` and `reason` in retention, subject_deleted, compacted); a chain ending in a `gone` step is truncated. The agent watch covers `/assigned/<node>/` only (`/replicas` no longer wakes it); `zig build bench-watch` measures it and reports a MISS honestly: `http_holds_max` 24 is below 50 agents (held 24, refused 26; with 50 holds p99 23 ms, 1 of 50 woken), so raising it is the owner's call. `demo/*.sh` are shell with a written reason each. `zcube local up|down` was cut here and then built: see the 2026-11-03 row.

Where: `docs/briefs/c1-7.md`, `docs/api.md`, `src/bench_watch.zig`
