# Slice 6b, part 2: what is built and what is next

Built (all with unit tests, `zig build test` and `tidy` pass): `peer_stream.zig` (handshake and
framed messages over a poll-driven socket, `connect` with a deadline), `peer_server.zig` (listener,
limiter, per-connection buffers, a test with a real loopback client and a stranger refused),
`agent_peer.load_identity`, `fetch_worker.zig` (driver over `fetch_plan` with an injectable
`Transport`; tests: a corrupt peer is struck and blamed once, the garbled chunk never reaches the
store, the registry finishes, a repeat fetch asks nothing, a tree no source has fails).

Cut, from the bottom of the brief's list: `swarm-smoke`, the fault-proxied fake registry, the
teeth build step, `DirImages` as `ctx.images` in `agent_run.zig`, the `zcube-agent fetch` command,
ZC-E0601 and ZC-W0602 (registry, goldens, site pages), the `--help` and table updates.

Design for the next session:
- Supervisor integration: FakeRuntime writes `fetch.json` into the container directory when the
  image is not in `DirImages` and a registry is configured; `fake_supervisor.supervise` runs
  `fetch_worker.fetch` after it writes `supervisor.pid` and before it spawns the command, so
  `agent_records.classify` already reports `starting`. `await_start` returns `started` once
  `supervisor.pid` exists when `fetch.json` does. A failure is `start_failed` with a new
  `Blame.fetch` that `start_failure` turns into ZC-E0601.
- The worker's `Transport`: peers over `peer_stream.connect` + `open_client` (expected node name)
  asking `GET <path>`; registry over plain HTTP (`GET /trees/<digest>`, `/chunks/<hex>`) in the
  smoke runner; peers and their filters from `GET /v1/list?prefix=/node-store/` and addresses from
  `/nodes/` (`--address` doubles as the peer HOST:PORT). Reports go to `<state-dir>/fetch.log`.
- The plan strikes a peer for the rest of the fetch after one bad chunk, so the registry then
  serves everything after it: the smoke's "registry exactly once" needs node 1 alone to fetch from
  the registry first, nodes 2 and 3 afterwards; node 3 must also not use the corrupting node.
- Traps: a `zig build test` run is the only revert-check that is true for tests reached through
  core.zig; `pkill -f` with a pattern in your own command line kills your shell.
