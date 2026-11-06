# `zig build check` keeps the tester run's build cache

*Decided 2026-11-06, by the supervisor's task.*

The last step of `zig build check` (`src/testing/check.zig`) runs `zig build test` as `tester` in a scratch worktree of HEAD. That worktree was removed after each check, and with it its local cache (`.zig-cache`) and its global cache (`.zig-global`), so every check rebuilt the whole test graph from nothing as `tester`.

## Decision

The scratch worktree is still fresh every time (the run sees exactly the committed tree), but the tester run's two caches live in `.zig-cache/zcube-check-cache/{local,global}` of the worktree that runs `check`, and the run passes `--cache-dir` for the local one.

- **Correctness.** Zig keys its cache by content, so a kept cache cannot make a stale result pass; it only skips work whose inputs are byte-identical.
- **Ownership.** `check` (root) creates the two directories empty and chowns just those directories; after that only `tester`'s build writes into them. The one exception is the package seed: the pinned `zigbox` package is copied from the invoking user's global cache into `global/p` only where missing (`cp --update=none`) and that `p` is chowned to `tester` again at once. The copied `zig-pkg` of the scratch tree is as before.
- **Worktrees.** The directory is under the worktree's own `.zig-cache`, so two worktrees never share one, and `rm -rf .zig-cache` resets it.
- **Disk.** A cache of the tester run holds about 0.4 GiB after one check (measured). Zig removes no old entries, so each commit adds the binaries it changed; `check` deletes the kept cache before a run once it is past 8 GiB (`kept_cache_max_bytes`), and `rm -rf .zig-cache` empties it by hand. The existing note about `.zig-cache/o` is unchanged.

## Measurements

`zig build check` wall time, 4-core container, whole command, same tree (main plus this change), run back to back:

| run | before | after |
|---|---|---|
| first | 1315 s | 1404 s (cold kept cache) |
| second | 923 s | 473 s |

The second run after is the number that matters: 923 s to 473 s. (The "before" first run had a cold cache for everything; the "after" first run also built the kept cache.)

Where: `src/testing/check.zig`, AGENTS.md ("Commands", `zig build check`).
