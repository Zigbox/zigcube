# The fetch driver over ZigboxImages (C2 slice 8, second part)

Status: the driver and the bundle codec are in and tested on real stores. The peer endpoint, the CLI wiring,
the registry fallback through `pull`, the `/pulls` feed and the second zigbox-smoke store are **not**.

## What is in

`src/zigbox_fetch.zig`:

* `encode` builds a *bundle* from a `ZigboxImages`: every tree record, a description of every object
  (id, mode, uid, gid, size, content hash, canonical xattrs, chunk hashes) and the image record. The format
  is in the file's header comment (`ZCB1`, little endian). `receive` applies one: tree records through
  `put_tree_record` (the first must be the digest asked for), objects through `begin_object`, and it returns
  the chunk list (each hash once, with its length) and the image record, which borrows the bundle. Every
  read is bounds-checked; a test cuts a real bundle at every length.
* `fetch` is the driver: nothing to do if `has(tree)`; else the first peer's bundle that `receive` accepts
  (a failure is `bad_list_fn`, ZC-W0602, and the claims are dropped); then the chunks through
  `fetch_worker.run_plan` (now over the `Images` seam instead of `DirImages`, with `lacking`, `rank_peers`,
  `Ranked`, `Run` public); then `import_image` with `expected_manifest` as an argument. Peers are trusted
  only against the full digest because `Digest` has no short form (owner decision).
* `fetch_worker.Transport` gained `bundle_fn` (default: none), so existing transports are unchanged.
* Five tests on two real Zigbox stores in a scratch directory: fetch by bundle and chunks and the tree
  rooted; a second fetch asks for nothing; a record for another manifest is `Refused` and nothing is rooted;
  a peer that corrupts chunks fails the fetch, is blamed, and nothing is rooted; a forged first tree record
  is a bad bundle; every cut of a bundle is refused.

Fixes found on the way: `zigbox_record_bytes_max` was 1 MiB and `ZigboxImages.export_image` could not
compile against Zigbox's `export_image` (80 KiB buffer); it was never instantiated before. The constant is
now Zigbox's `image_record_bytes_max`.

## Not done, in the order to do it

1. **The endpoint.** `GET /v1/peer/bundle/<full digest>` in `peer_serve.zig`/`peer_server.zig`. A bundle can
   be megabytes (`bundle_bytes_max` is 64 MiB), more than `peer_serve.scratch_bytes`, so it needs a
   streamed or separately sized body and the `Images` seam needs a `bundle_fn`; `fetch_cli.reply_bytes` and
   the HTTP read limit must grow with it. Then `Net.bundle` in `fetch_cli.zig` (peers only) and docs in
   `docs/peer.md`, `docs/swarm.md`.
2. **CLI mode.** `zcube-agent fetch` opens a `DirImages`; it needs a mode that opens a Zigbox store and
   runs `zigbox_fetch.fetch` inside `store.namespace` (Z6), with the manifest from the assignment's pinned
   image.
3. **Registry fallback** = Zigbox's `pull` (`zig-pkg/.../src/pull.zig`: `Request`, `Workspace` ~15 MiB,
   `HostReal`, `Result.blobs[i] = {digest, bytes, outcome}`), called when `fetch` returns
   `TreeUnavailable` or `ChunkFailed`. Not tested here: needs a registry (Z8 or the network).
4. **`/pulls` feed** (Z5 bytes per blob): waits on #61 (slice 7, `claude/c2-slice7`), not on main. Do not
   merge that branch; after it lands, merge main and write `pull.json` from `Result.blobs`.
5. **zigbox-smoke** second store, two agents on one host (needs 1-3; needs KVM, absent here).

## Traps

* `ZigboxImages` `read_chunk` of an unknown hash calls `reindex` (walks every root). `lacking` does that
  once per chunk of a fresh fetch: cheap with a few roots, quadratic with many. Fix by making `lacking`
  ask the adapter for "held" without a reindex, or index once.
* `zig build test -Dtest-filter=X` with a name that matches several tests ran 1 test and said
  `success` for me; to see tests by name run the unfiltered test binary (`grep -l` the test name in
  `.zig-cache/o/*/test`, run it).
* Peer chunks that fail the plan's hash check are blamed; the registry source is not served in this mode
  (`chunk_fn` must answer `.refused` for `.registry`), so the plan fails with `ChunkFailed`, not a registry
  read.
