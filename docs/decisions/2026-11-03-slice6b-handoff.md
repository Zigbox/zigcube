# Slice 6b: what is built and what is next (after part 3)

Built, all with unit tests (`zig build test` and `tidy` pass): `peer_stream`, `peer_server`,
`agent_peer.load_identity`, `fetch_worker` (parts 1-2); in part 3:

- Review fixes: `DirImages.read_chunk` no longer refuses a chunk of exactly `swarm_chunk_bytes`
  (stat when the buffer fills; tests through DirImages and through `peer_server`); `write_whole`
  uses a random temporary name with exclusive create; DirImages is documented as one thread's;
  `fetch_worker.fetch` never asks a peer when the digest is not the full 67 characters
  (decisions/2026-11-03-full-digest-untrusted.md, owner confirmation pending).
- Agent wiring: `--images-dir` makes `DirImages` the agent's `ctx.images`; `--peer-listen` starts
  the peer server (`agent_run.Swarm`); config test.
- `zcube-agent fetch` (`fetch_cli.zig`): the worker over the registry (plain HTTP) and peers named
  with `--peer NAME=HOST:PORT` (each assumed to hold everything).
- ZC-E0601 and ZC-W0602: registry, goldens, testdata, site pages (written by a Haiku agent, the
  goldens confirmed by `zig build test`). Registry entries must follow the enum order.
  `fetch_cli` prints ZC-E0601 as text; the full diagnostic raise (Diag) is not wired. ZC-W0602 has
  no raise site yet (the worker counts `bad_lists` only).

Cut (from the bottom of the brief's list; NOT done):
- The supervisor running `fetch` before the command, with `fetch.json`, `starting` while it runs,
  `Blame.fetch` -> ZC-E0601 (design below).
- Peer and filter discovery from the server (`/v1/list?prefix=/node-store/`, `/nodes/`).
- D: fake registry (fault-proxied for node 3), the teeth fault, `zig build swarm-smoke` with a
  1 MiB chunk. E: `--help` is done; `peer.md`, `api.md`, `keys.md` tables are not.
- No revert-check was run for the three part-A fixes (tests pass; they were not shown to fail
  without the fix).

Design for the supervisor integration: FakeRuntime writes `fetch.json` into the container
directory when the image is not in `DirImages` and a registry is configured;
`fake_supervisor.supervise` runs the fetch after writing `supervisor.pid` and before spawning the
command, so `agent_records.classify` already reports `starting`. `await_start` returns `started`
once `supervisor.pid` exists when `fetch.json` does. A failure is `start_failed` with a new
`Blame.fetch` that `start_failure` turns into ZC-E0601. The plan strikes a peer for the rest of a
fetch after one bad chunk, so the smoke's "registry exactly once" needs node 1 to fetch first.

Traps: `zig build test` (not `-Dtest-filter`) is the only true revert-check; zig-pkg must be
populated by hand (AGENTS.md); `pkill -f` with a pattern in your own command line kills your shell;
a concurrent `zig build` while a subagent edits `src/diag/codes.zig` fails on its comptime asserts.
