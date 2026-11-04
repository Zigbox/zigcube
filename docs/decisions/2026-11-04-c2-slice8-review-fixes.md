# C2 slice 8: review fixes (M1, M2, S1-S4) and the handoff for M3 and M4

Status: decided 2026-11-04, on PR #66. Fixes the first review of slice 8.

## Decisions

- **M1 (overlapping images).** `put_chunk_impl` marks a chunk used for every claim that lists
  it and writes only into claims that are not complete; `settle` runs at the end of
  `begin_object`, so an object the store already holds completes at once. Test: `zigbox fetch:
  a second image sharing files with a held one`.
- **The `-Dtest-filter` trap.** A test that a filter leaves out never runs, and the files it
  imported leave the run unseen. The peer files are now imported in a file-level `comptime`
  block in `src/tests.zig`, which a filter cannot skip. New test files that a test block alone
  imports would be dropped the same way: add them to that block.
- **M2 (one registry fallback).** The supervisor's own Zigbox `pull` is the fallback;
  `fetch --source`, `zigbox_pull.zig` and `registry_chunks` in the Zigbox path are deleted.
  Reason: Zigbox's pull may create namespaces, and the supervisor already owns that process
  boundary. The supervisor writes `containers/<name>/pull.json` (`pull_report.zig`, atomic
  `.tmp` + rename) from the pull's blobs. Cost: a fetch that fails reports nothing, so its
  peer figures are lost; `pull.json` then shows registry bytes only.
- **Units.** `registry_bytes` is compressed blob bytes. `cached_bytes` is store chunk bytes for
  a peer fetch and blob bytes for a pull. Both are documented in `pull_report.zig` and
  `zigbox_fetch.Report`.
- **S1.** The fetch's stderr is `<container dir>/fetch.log`.
- **S2.** The image record's `.manifest` is checked when the bundle is received; a mismatch is
  `BadBundle`, the peer is struck and the next is asked. Tree records of a rejected bundle stay
  unrooted until gc.
- **S3.** `ZigboxImages.walked` is true after a `reindex` until something writes
  (`put_tree_record`, `begin_object`, `end_claims`, `import_image`). N unknown hashes cost one
  walk. A chunk written by another process (the supervisor's pull) is found at the next write
  or restart, not by a miss.
- **S4.** `zigbox_fetch_deadline_ms` (`constants.zig`) kills a fetch that outlives it.
- **E0506** now names the target it failed for; a refused record gives only its own cause.

## Handoff for M3 and M4 (not started)

- **M3.** The fetch still does not run in `store.namespace`. Writes by `write_pull_record`
  and `fetch_swarm` run in the single-threaded supervisor; `zigbox_images` opens the store
  without a namespace. Any namespace work must reach `ZigboxImages.open` and Zigbox's `pull`.
- **M4.** zigbox-smoke should assert: registry bytes in `pull.json` after a registry-only
  pull, a non-empty `fetch.log` after a failed fetch, and the deadline's kill. Trap: a stale
  `containers/<name>/pull.json` from an earlier pull of the same name must not be shown for a
  later one (the supervisor rewrites it only after a successful pull).
