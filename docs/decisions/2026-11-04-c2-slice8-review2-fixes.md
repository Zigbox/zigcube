# C2 slice 8: second review fixes (M1, M2, S1a, S1b, S2-S4)

*Decided 2026-11-04, by the slice (PR #66).* Supersedes the **S2** item of
`2026-11-04-c2-slice8-review-fixes.md`: a record for another manifest is no longer a strike.

- **A bundle's objects are its tree's.** `receive` stores the tree records the asked tree
  reaches (others are ignored), then lists the distinct objects those records name
  (`ZigboxImages.collect_checked`). The bundle must send exactly those, each once, with the
  size and content the tree's entry gives. An added, missing, repeated or altered object is
  `BadBundle` (strike, ZC-W0602, next peer). So no size or count from the wire reaches an
  assert. The old receiver passed the peer's size to `object.chunk_count`, which asserts, and
  it let forged objects push the chunk count past `fetch_chunks_max`, another assert.
- **Our limits are not a peer's fault.** The objects and chunks are now the digest-checked
  tree's, so too many of either is `TooLarge`: no strike, no next peer, and ZC-E0601 says the
  tree is too large for a peer fetch. The review asked for `BadBundle` with a strike. That
  would strike every honest peer of a large image. `zigbox_claims_max` is raised to the walk's
  `entries_max` (65,536, asserted at comptime), so every tree the walk accepts can be claimed.
- **Another manifest's record is not a strike (S1a).** A peer exports the newest record of a
  tree (`image_peer.export_record`), and the pinned Zigbox has no way to export the record of a
  named manifest. The protocol therefore cannot ask for one. Such a bundle is `OtherImage`: it
  is counted in `Report.other_images` and the next peer is asked. If no peer has the record,
  ZC-E0601's cause says so.
- **Gaps in the pinned Zigbox (`c314076`), to raise with its owner.**
  - `store/images.zig` (`parse`, `load`, `render`) is not exported, which has three effects:
    - `record_names` matches the line `    .manifest = "sha256:HEX",` in the record text.
    - `ZigboxImages.own_record` reads `<store>/images/<hex>` (the path `images.save` writes)
      directly.
    - A per-manifest export cannot be served.
  - In every case `import_image` parses the record and has the final say. A layout change in
    Zigbox makes the match fail closed: no peer's record is taken, and the registry pull runs.
- **Whole is not imported (S4).** A whole tree skips the peers only when the store already
  holds this manifest's record (`own_record`), which is then imported again. Otherwise the tree
  is fetched as any other: its chunks are found held and the peer's record is imported.
- **Refusals.** A record Zigbox refuses at the end is reported with its reason
  (`fetch_cli.refusal_text`). The peer is struck only for `too_large`, `malformed`,
  `wrong_tree` or `wrong_manifest`.
- **Not done: the peer server's 64 MiB bundle buffer** (NIT). The `bundle_fn` seam fills a
  caller's buffer, so sizing the buffer from the content would mean changing the seam. The
  buffer comes from `page_allocator`, so only the pages written are mapped.

Where: `docs/swarm.md` ("The Zigbox store path"), `src/zigbox_fetch.zig`,
`src/zigbox_images.zig`, `src/fetch_cli.zig`.
