# C2 slice 8: review fixes (M1, M2, M3, S1-S4) and the handoff for M4

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

## M3: the fetch writes in Zigbox's store namespace

- **Where.** `zcube-agent fetch --zigbox-store` runs everything (store open, network, every
  write, the report file and the stdout line) in the child of `zigbox.store.namespace.run`
  (`fetch_cli.fetch_in_namespace`): the child is a copy, so only its exit code and what it wrote
  come back, and the fetch's own output is already the command's. The process uses
  `std.Io.Threaded.init_single_threaded` and checks `/proc/self/status` for one thread
  (ZC-B0002 otherwise). The supervisor's spawn is already a fresh exec, so no thread exists.
  `squash_owner` is ignored: no Zigbox call the fetch makes takes an owner.
- **Serving.** A peer server runs threads, outside the namespace, so `lstat` there gives host
  ids. `ZigboxImages.object_meta` now takes mode, owner and attributes from the tree entry
  (`describe`), and checks that they make the object id, instead of `lstat` and gathering the
  file's attributes. Without that, a store written in the namespace with the full map served
  bundles that no receiver accepts (ZC-W0602).
- **Latent bug fixed.** `NamespaceJob` sets `Opened` to `.{}`, not `undefined`: `chunk_bytes`
  was read as 0xAA garbage.
- **Gap in the pinned Zigbox (reported, not worked around).** `store.read_chunk` checks an
  object of one chunk (no `.chunks` list) by recomputing its id from the file's own `lstat` and
  attributes (`chunk_read.zig`, `id_holds`). A peer server reads outside the namespace, so on a
  host with the full map every one-chunk object of a container id other than 0 is `Damaged`
  and is not served. Zigbox's rule is that every store operation runs in the namespace, but a
  peer server with threads cannot. Zigbox could take the expected attributes from the caller
  (the tree entry), check the content hash against the tree's, or offer a serving read that
  does not depend on the view. Until then a peer fetch of such an image fails
  (ZC-E0601) and the supervisor's pull gets it from the registry. The test makes
  its container-owned file two chunks long for this reason.
- **What was exercised (root, Postgres not involved).** With `uidmap` installed and
  `root:200000:65536` in `/etc/subuid` and `/etc/subgid` (full map):
  `zigbox_fetch_owner_test.zig` passes. With the fetch's `namespace.run` bypassed it fails:
  `zigbox .{ .uid = 200999, ... }, fetch .{ .uid = 1000, ... }`.
  `zigbox_images.zig`'s test re-owns every object file to 200999 and still replicates.
  A fetch SIGKILLed while its namespace child waits on a silent peer leaves no child (Zigbox's
  child has `PDEATHSIG`), tested in `zigbox_fetch_owner_test.zig`.
  Under `zig build check` as `tester` (no subordinate range, so the one-id map), the owner test
  runs with every owner 0. Not exercised: a fetch on a one-id-map host of an object whose id
  commits to an owner other than 0. It should fail to chown, exit 2, and fall back to the
  supervisor's pull. The CI container's subid setup is unknown.

## Handoff for M4 (not started)

- **M4.** zigbox-smoke should assert: registry bytes in `pull.json` after a registry-only
  pull, a non-empty `fetch.log` after a failed fetch, and the deadline's kill. Trap: a stale
  `containers/<name>/pull.json` from an earlier pull of the same name must not be shown for a
  later one (the supervisor rewrites it only after a successful pull).
- **M4, from M3.** zigbox-smoke can also check that a peer-fetched container's object files have
  the owners and modes of the same image pulled from the registry. On a CI host without
  subordinate ranges both are 0, so the check only has teeth with `uidmap` and a range for the
  runner (`zigbox_fetch_owner_test.zig` shows how). Images with one-chunk files owned by
  container ids other than 0 hit the `read_chunk` gap above: expect the fetch to fail and the
  pull's registry bytes, not a smoke failure.
