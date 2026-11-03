# Slice 6b: what is built and what is next (after part 3)

Built, all with unit tests (`zig build test` and `tidy` pass): `peer_stream`, `peer_server`,
`agent_peer.load_identity`, `fetch_worker` (parts 1-2); in part 3:

- Review fixes: `DirImages.read_chunk` no longer refuses a chunk of exactly `swarm_chunk_bytes`
  (stat when the buffer fills; tests through DirImages and through `peer_server`); `write_whole`
  uses a random temporary name with exclusive create; DirImages is documented as one thread's;
  `fetch_worker.fetch` never asks a peer when the digest is not the full 67 characters
  (decided by the owner, 2026-11-03).
- Agent wiring: `--images-dir` makes `DirImages` the agent's `ctx.images`; `--peer-listen` starts
  the peer server (`agent_run.Swarm`); config test.
- `zcube-agent fetch` (`fetch_cli.zig`): the worker over the registry (plain HTTP) and peers named
  with `--peer NAME=HOST:PORT` (each assumed to hold everything).
- ZC-E0601 and ZC-W0602: registry, goldens, testdata, site pages (written by a Haiku agent, the
  goldens confirmed by `zig build test`). Registry entries must follow the enum order.
  `fetch_cli` prints ZC-E0601 as text; the full diagnostic raise (Diag) is not wired. ZC-W0602 has
  no raise site yet (the worker counts `bad_lists` only).

Part 4 (the cut items, now done):
- Supervisor integration as designed below: `fetch.json`, `fetch.log` (the fetch's stderr),
  `Blame.fetch` -> ZC-E0601; `zcube-agent --registry HOST:PORT` (needs `--images-dir`).
- Peer discovery: `zcube-agent fetch --server HOST:PORT` reads `/nodes/` and `/node-store/`.
- Raise sites for ZC-E0601 and ZC-W0602 with goldens.
- D: `src/swarm_smoke.zig` (`zig build swarm-smoke`, three agents, fake registry, one 1 MiB chunk,
  node 3's registry black-holed) and `swarm-smoke-teeth` (agent built with verification skipped;
  passes only if the smoke fails). Test fault `<state-dir>/faults/peer-corrupt` makes a peer flip
  the first body byte of every chunk reply (read at agent start).
- Supervisor review fixes M1 and S2: `fetch_cli.Net` keeps one stream per peer (reopened after an
  error or `peer_connection_requests_max` requests); a non-200 head is `.refused`. Test in
  `peer_server.zig` (more requests than `peer_handshakes_per_source_max`).
- Revert checks: chunk read, peers list and `write_whole` temp name each fail a test without the
  fix (a test was added for `write_whole`: `a write never touches another writer's temporary
  file`; the later fix session may still harden it).
- Docs: `agent.md`, `api.md`, `keys.md`, `peer.md`; AGENTS.md lists the smoke.

Observations: in a teeth run a later replacement replica on node 3 still reached `running` with an
empty `fetch.log` (probably chunk 0 from node 2 on a retry); not explained. `-Dtest-filter` ran
nothing for new tests here; use the full `zig build test`. tidy bans `**` formatting oddities and
`@import("root")` outside the allowlist (`zcube_agent.zig` added).

Traps: `zig build test` (not `-Dtest-filter`) is the only true revert-check; zig-pkg must be
populated by hand (AGENTS.md); `pkill -f` with a pattern in your own command line kills your shell;
a concurrent `zig build` while a subagent edits `src/diag/codes.zig` fails on its comptime asserts;
`say()` in the smokes truncates at 512 bytes; a worktree under `.claude/worktrees/` breaks tidy.
