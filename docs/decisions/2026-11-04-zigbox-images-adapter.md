# The Zigbox store adapter (C2 slice 8, first part)

Status: partly done. `src/zigbox_images.zig` is in; the fetch worker, the registry fallback, `/pulls` and the
second zigbox-smoke store are not (see "Not done").

## What is in

`ZigboxImages` implements the `node_store.Images` seam over a real Zigbox 0.3.0 store (pin: c314076).
Serving half: `summary`, `has`, `chunk_list`, `read_chunk` by chunk hash, with `chunk_read.read_chunk`
verifying every read. Receiving half, outside the seam because the seam cannot carry it: `tree_digests` and
`tree_record` / `put_tree_record` (every directory is a tree record of its own, checked by `put_checked`),
`object_meta` / `begin_object` (claim an object by its attributes and chunk hashes; refused unless
`object_id(content, attrs) == id`), the seam's `put_chunk` (lands a chunk in every claimed object that lists
its hash), `import_image` (the record, with the owner rule: `expected_manifest` is an argument, never read from
the peer's text; a mismatch is `Refused` and nothing is written; tags are dropped).

Tests (real stores in a scratch directory, chunks of 8 bytes): a tree copied A to B and `has` true on B, a
wrong chunk body refused, a forged claim refused, the record refused for another manifest with no root written
and accepted for the right one, the record of an incomplete tree refused.

## Why the seam is not enough (report to the owner)

The seam and wire are keyed by chunk hash and carry a chunk list. Zigbox is keyed by (object id, chunk index)
and has no hash-to-object index. To write an object it needs its mode, owner and attributes (the id commits to
them), and a directory is a tree record. So the fetch needs three things on the wire the chunk list does not
have: the tree records, the per-object description (`ObjectMeta`) and the image record. `list_matches` no
longer binds the list to the tree digest either: the tree digest is Zigbox's, not BLAKE3 of a list. The
adapter keeps its own hash-to-position index (made when a tree is listed, rebuilt from the roots on a miss; a
stale entry is `NotFound`, never a wrong chunk).

## Not done (cut, in the order of the brief)

* The fetch worker and the peer protocol on the adapter: needs the wire additions above and a decision on
  how a peer is asked for them (a new `GET /v1/trees/<digest>` bundle is the smallest).
* The registry fallback as Zigbox's `pull`, and Z5's per-blob bytes into `/pulls`: slice 7 is not on main,
  so there is no seam to mark yet.
* zigbox-smoke's second VM-less store (two agents on one host): needs the worker.
* Not run: zigbox-smoke (no KVM in this container).

## Traps

* `chunk_hashes` asserts its `out` is exactly 4096 hashes and `fs.read` asserts its buffer is at most 256 KiB:
  Zigbox does not export those two constants, `constants.zigbox_*` repeat them.
* The Zigbox tests' `Store.at` wants the parent of the root to exist.
* `zig build test -Dtest-filter=X` filters by test name only, and a filter that matches one test says
  `1/1 passed`; filter on a word in each test's name.
