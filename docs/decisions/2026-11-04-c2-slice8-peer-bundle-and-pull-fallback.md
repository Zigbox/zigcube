# C2 slice 8, third part: peer bundle endpoint, fetch wiring, pull fallback

Status: done on `claude/c2-slice8` (ea4bea9, 7043838, 58d46c8).

## What exists

- **Endpoint.** `peer_serve` answers `path_bundle` from `node_store.Images.bundle()`;
  `zigbox_fetch.serving()` builds the Zigbox-backed seam. `peer_server` opens one
  `ZigboxImages` per slot (`Config.zigbox_store`) and gives each request a bundle buffer. The
  core has no allocator: the shell owns the buffer. Peers are trusted only against the full
  64-hex digest; the expected manifest comes from the assignment, never from the peer.
- **CLI.** `zcube-agent fetch --zigbox-store DIR --manifest HEX --source PEER` takes the peer's
  bundle over the peer stream (16 KiB records).
- **Fallback.** With no peer holding the tree, `fetch` calls Zigbox `pull` (`src/zigbox_pull.zig`,
  `pull_image`, `Pulled.blobs` carries digest, bytes, outcome).

## Not done / traps

- The supervisor's `fetch` launch in `agent_run` does not yet pass `--zigbox-store`,
  `--manifest`, `--source`. `--registry` is still required in Zigbox mode.
- The fetch does not run inside `store.namespace` (Z6).
- `docs/peer.md` and `docs/swarm.md` are not updated.
- `lacking`'s reindex trap remains.
- The pull fallback has only host unit tests; it was never run against a registry.
- No host end-to-end test of peer server plus client with two Zigbox stores yet (Rig in
  `peer_server.zig` needs an optional `zigbox_store`).
- `zigbox-smoke` with a second agent and store was not extended: it needs KVM and a QEMU guest,
  absent here.
- Z5 (per-blob pull bytes into `/pulls`) skipped: slice 7 ("pull stats") is not on main.
