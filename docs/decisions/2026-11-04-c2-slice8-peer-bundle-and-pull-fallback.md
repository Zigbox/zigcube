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

## Follow-ups from the supervisor (same slice)

- **Supervisor launches the fetch.** `ZigboxRuntime.Options.fetch` (`launch.Fetch`: exe, node,
  state dir, server, registry) goes into the launch spec when the tree is a full `b3:` digest and
  the reference is pinned (`name@sha256:HEX`; `launch.manifest_of` reads the manifest from it: the
  manifest is the assignment's). `zigbox_supervisor` runs `<exe> fetch --node .. --state-dir ..
  --zigbox-store <located root> --manifest .. --digest .. [--registry ..] [--server ..]` when
  Zigbox's start says ZBX-E0410 (`image.Steps.fetch`, before the pull), then starts again.
- **Deviation:** `--source` is *not* passed. The supervisor keeps the pull itself, in its own
  single-threaded process (Zigbox's pull may make namespaces; I could not check that the fetch
  process stays single-threaded), and says its own ZBX diagnostics. `fetch --source` stays for
  other callers. A failed fetch falls through to the pull.
- **`--registry` is optional** with `--zigbox-store`; without it, a tree no peer has is ZC-E0601
  naming the peers asked ("no peer, and no registry is given" when there are none).
- **End-to-end test** (`peer_server.zig`, "a Zigbox store serves a tree..."): real peer stream,
  two stores; a corrupting peer fails with `ChunkFailed`, a wrong manifest is `Refused` (data may
  land, nothing is rooted), an absent tree is `TreeUnavailable`, then the honest fetch roots it.
  `Opened.chunk_bytes` / `Config.zigbox_chunk_bytes` exist for the tests only: the store's chunk
  size is not recorded in the store, and a store opened with another size than it was made with
  trips `zigbox_images.chunk_length`'s assertion in `reindex` (a hard abort in a peer server).
- Docs: `docs/peer.md` (the bundle route) and `docs/swarm.md` (the Zigbox store path).

## Not done / traps

- **The agent serves its Zigbox store (added after the first report).** With `--runtime zigbox
  --peer-listen` and no `--images-dir`, `Swarm.start` finds the store (`store.open.open` with
  `.create`, so a node that has not pulled yet already serves an empty store), passes its root to
  the peer server as `zigbox_store`, and gives the server an unused chunk directory
  `<state-dir>/peer-chunks`. Test: `peer_server.zig`, "an agent configured for Zigbox only
  serves its store's tree to a peer fetch" runs `Swarm.start_with`. The summary is reported from the Zigbox store: `Swarm.zigbox` (an `Opened` on the agent's thread) is `Shell.images` in Zigbox mode, checked in the same test; the `Shell` line in `run` itself is untested, and so is the real `Swarm.start` (store location from the environment; two lines over `start_with`).
- The supervisor's fetch and the new `launch.Fetch` spec field have unit tests only
  (`image.start_with_image` with a scripted fetch; `manifest_of`); no process-level test, and
  `zigbox-smoke` was not extended (no KVM here).
- The fetch does not run inside `store.namespace` (Z6).
- `lacking`'s reindex trap remains.
- The pull fallback in `fetch --source` was never run against a registry.
- Z5 (per-blob pull bytes into `/pulls`) skipped: #61 is still in review.

## What is left (final state, commit 65254d1)

- **Z5** (bytes into `/pulls`) is not started; it waits for #61 to merge. A fresh session does it.
- The chunk summary is reported from the Zigbox store (`Swarm.zigbox` is `Shell.images` in Zigbox
  mode; `node_images` in `agent_run.zig`), tested through the seam in `peer_server.zig`'s
  "an agent configured for Zigbox only serves ..." test. Not tested: the `Shell` wiring in `run`,
  the real `Swarm.start` store lookup from the environment, and the scheduler's locality reading
  the Zigbox-sourced summary end to end.
- A summary taken before a tree is imported was expected to be empty, but the fixture's `import`
  already roots the tree in a full test run (and not in a filtered one: unexplained), so the test
  asserts only the after state.
- `check` prints a `failed command: .../test` line with PASS: it is the stderr echo of the
  ZC-W0601 warning that the lying-peer tests provoke; `zig build test --summary all` reports 14/14
  steps succeeded.
- REVIEW.md: covered interfaces (`--help`, docs, config test), start-failure diagnostics (ZC-E0506,
  no ZC-B), test reachability and wasm cleanliness. Not covered: SIGKILL/exit-path tests of the new
  Swarm start, the supervisor fetch spawn at process level, Postgres (store untouched).
