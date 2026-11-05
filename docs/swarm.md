# The swarm: summary, estimate and fetch plan (C2 slice 4)

Pure core modules for C2 (docs/briefs/c2.md): what a node tells the cluster about its chunk store,
how the scheduler estimates how much of an image a node already holds, and how a node fetches the
chunks it lacks. No key, record, API or wire encoding is defined here: slice 5 stores the summary
and slice 6 serves chunks. All of it is core code (no clock, thread, file or allocation) and is in
the `wasm32-freestanding` build.

| Module | What it is |
| --- | --- |
| `src/chunk_summary.zig` | `Filter` (Bloom filter over chunk hashes), `Sketch` (bottom-K sample of a tree), `locality_bytes` |
| `src/fetch_plan.zig` | `Plan`, the fetch state machine; `raise_blame` (ZC-W0601) |
| `src/sim_images.zig` | The simulated world: chunks, tree versions, nodes that lie, stay silent or refuse |
| `src/sim_swarm.zig` | `sim-swarm`: the plan and the estimate against that world, one seed |

## The filter

A Bloom filter over chunk hashes. The chunk hash is BLAKE3 output, so the probes come from the hash
itself: a double hash from bytes 0..16 gives `summary_filter_hashes` (7) probes. 10 bits per chunk
of capacity (`summary_chunks_capacity`, 64 Ki chunks) gives a false-positive rate of 0.82 % at
capacity. There are no false negatives. A false positive costs one `refused` answer, never a wrong
chunk: the plan treats the filter as a hint.

## The sketch and the estimate

A `Sketch` keeps the `summary_sketch_keys` (64) smallest keys of a tree's distinct chunks, a key
being bytes 16..24 of the hash, each with the chunk's size (12 bytes an entry). Keys are uniform, so
the sample is a uniform sample of the tree's chunks, and a tree of at most 64 chunks is exact.

`locality_bytes(target, held)` estimates how many bytes of the target tree a node holds, given the
sketches of the complete trees on the node:

1. A held tree with the target's digest is worth the whole target.
2. Else the target's sample is compared with the held samples (a key is held if any
   of them has it), over the key range both cover exactly. The share of the target's sampled bytes in
   that range that the held trees hold, applied to the target's size, is the estimate. It is exact when
   both are exact. Otherwise the range is below the smallest limit among the target's and the held
   samples (each sketch is exact below its own limit, the union only below the smallest of them),
   and the estimate is a ratio over the target's samples in that range: about 64 of them when the
   held trees are no larger than the target (standard deviation about 6 % of the tree), and fewer
   as the held trees' limits drop, as with many versions of a churning image.

The target's sketch is an input. Where the scheduler gets it is slice 5's question.

## The fetch plan

```
        next(now) ──► request{chunk, peer | registry} ──► caller asks that source
                 └──► wait{until}   ──► caller sleeps or a result arrives ──► next
                 └──► done | failed{chunk}
   receive(id, bytes)    BLAKE3 of the bytes against the chunk list: verified | bad_hash
   receive(id, refused)  the peer does not have it: another source
   receive(id, timeout)  the same; three in a row give the peer up
```

* **Trust.** A peer is trusted for speed only. `receive` hashes the bytes itself, so a chunk the
  plan calls verified matched its hash, whatever the caller did. A peer that sends bytes that do
  not match is struck for the fetch (no more requests to it) and reported once with ZC-W0601
  (`take_blame`, `raise_blame`).
* **Source.** A peer whose filter may hold the chunk, not struck, gone or already tried for it, with
  a free slot (`fetch_in_flight_per_peer_max` 2, `fetch_in_flight_max` 8) and bandwidth. When none
  exists the registry serves the chunk at once if peers claimed it and all failed it or there is no
  peer; otherwise after `fetch_peer_wait_ms` (30 s) from the start. A chunk the registry fails
  `fetch_registry_attempts_max` (4) times fails the fetch.
* **Caps.** A token bucket per peer and one for the node, each holding one second of its rate and
  allowed to go into debt by one chunk: bytes requested never exceed `rate * elapsed + rate +
  chunk`.
* **Memory.** The caller gives the plan a `ChunkState` per chunk and the peers' filter bytes.

## The Zigbox store path (slice 8)

With `--zigbox-store ROOT --manifest sha256:HEX`, `zcube-agent fetch` fills a Zigbox store
instead of a chunk directory (`zigbox_fetch.zig`, `fetch_cli.zig`):

1. A tree already whole in the store, for which the store already holds this manifest's image
   record, is imported again from that record and no peer is asked. A tree that is whole under
   other manifests' records only is fetched like any other (its chunks are found held), so its
   record for this manifest is imported too.
2. Each peer, in turn, is asked for the tree's bundle (`GET /v1/peer/bundle/<digest>`, docs/peer.md)
   and the chunks the store lacks are fetched under the same plan as above (peers first, hashes
   checked by the plan itself). The tree is then rooted for the manifest the assignment names.
   A bundle is held to the tree it claims: its tree records to their digests (only those the
   tree reaches are kept), and its objects must be exactly the distinct objects those records
   name, each once, with the size and content the tree's entry gives. A bundle that adds an
   object, leaves one out, sends one twice or gets one wrong is a bad bundle: the peer is
   struck (ZC-W0602) and the next one is asked. Tree records of a rejected bundle stay in the
   store, unrooted, until gc.
3. The bundle's image record is checked against the assignment's manifest as soon as the bundle
   arrives. A peer sends the newest image record of the tree (Zigbox's `export_record`), so an
   honest peer that ran another image of the same tree sends that one's: it is counted, not
   struck, and the next peer is asked. If no peer sends this manifest's record, ZC-E0601 says
   so. A record Zigbox refuses at import is reported with Zigbox's reason (`images.refusal`);
   the peer is struck only when the record is its own fault (too large, malformed, for another
   tree or another manifest).
4. A tree with more objects than one fetch claims (`zigbox_claims_max`, equal to the walk's
   `entries_max`) or more chunks than it fetches (`fetch_chunks_max`) is too large for a peer
   fetch on this node. That limit is this node's, and the counts come from the digest-checked
   tree, so no peer is struck and no other peer is asked: ZC-E0601 says the tree is too large.
5. With no peer that has the tree, the fetch fails with ZC-E0601, which names the peers asked.
   There is no registry fallback inside `fetch`.

The registry fallback is the supervisor's own Zigbox `pull` (`zigbox_supervisor.zig`), which
runs when the fetch exits non-zero. After a successful pull it writes
`containers/<name>/pull.json` from the pull's blobs (`pull_report.zig`) for `/pulls`. The fetch's
stderr goes to `<container dir>/fetch.log`. The supervisor kills a fetch that runs past
`zigbox_fetch_deadline_ms` (the fetch's total budget plus a minute). A fetch that fails writes no
peer figures, so `pull.json` shows only the registry's bytes.

Units in a `/pulls` record: `registry_bytes` is compressed blob bytes (a blob a pull resumed
counts whole); `cached_bytes` is store chunk bytes for a peer fetch (what the store already
held) and compressed blob bytes for a pull (blobs it already had).

`--registry` is optional in this mode (it is still required with `--images-dir`).

**The store namespace (M3).** In this mode every store write of the fetch (tree records,
objects, chunks, the image record) and its network work run in Zigbox's store namespace
(`zigbox.store.namespace.run`), in its child of one thread, as Zigbox's own `pull` does. So an
object of container id 1000 lands as the host id the subordinate range gives it, and the store
is file for file what a pull leaves (`zigbox_fetch_owner_test.zig`). The child's exit code is the
fetch's; a child that cannot be made is ZBX-E0419 and exit 2. `fetch` checks that it has one
thread first (ZC-B0002 otherwise). On a host with only the one-id map (ZBX-W0201) every owner is 0
inside, so an object whose id commits to another owner cannot be written: the fetch fails and the
supervisor's pull (which squashes owners) runs.

The serving side (`peer_server`, threads, outside the namespace) sends each object's attributes
from its tree entry (`ZigboxImages.describe`), never from `lstat`, which outside the namespace
gives the host's ids. Zigbox's `read_chunk` still checks an object of one chunk against an id
made from the file's own `lstat`: outside the namespace such an object reads as damaged and is
not served whenever its host owner is not its container owner (any container id but 0 on a
root agent with the full map; every one-chunk object on an agent that is not root). And a peer
server that is not root cannot open an object owned by an id of its range that others may not
read. Both are gaps in the pinned Zigbox, reported in
`docs/decisions/2026-11-04-c2-slice8-review-fixes.md`. They are not what failed the smoke's first
`peers_fetch` runs: that was the supervisor's single-threaded Io having a failing allocator, which
made the fetch's spawn end in OutOfMemory (`docs/decisions/2026-11-05-c2-slice8-peers-fetch-passes-as-cube.md`).
With that fixed, `peers_fetch` passes as `cube` in CI (python:3.12-slim, 115,409,299 peer bytes, run
41955830319). The smoke does not prove the gaps closed: the images it moves may simply have no file
that meets them.

## sim-swarm

`zig build sim-swarm [-Dseed=N] [-Dops=N]` runs the simulation natively and as WASM and compares
the reports byte for byte. `zig build -Doptimize=ReleaseSafe sim-swarm-exe` installs
`zig-out/bin/sim_swarm <seed> <ops>` or `--seeds A..B <ops>`. The seed draws a universe of 128 to 512
chunks, 2 to 6 versions of one tree that share most chunks, 3 to 12 nodes that are honest, liars,
silent or refusers (some with stale filters), and low byte-rate caps so they bind. Operations: a
node fetches a version, the estimate is checked against the exact count, a node loses chunks.

Checked: a chunk is accepted exactly when its bytes are right; only a liar is struck; no chunk
twice; a peer is asked only for what its filter claims, never again for a chunk it failed, never
after a strike; the caps hold; every fetch finishes (the registry is honest) within a bound and the
bytes by source add up; the estimate is exact when both samples are, else within 30 % of the tree.

`zig build sim-swarm-teeth` builds the simulator with the plan's test-only fault ("accept a chunk
without checking it", declared only by `src/sim_swarm_teeth_main.zig` as `swarm_teeth_skip_verify`)
and passes only if a seed in 1..10 fails. Both run in `zig build check`.
