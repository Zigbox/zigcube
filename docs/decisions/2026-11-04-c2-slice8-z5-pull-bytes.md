# C2 slice 8, last part: Z5 (Zigbox fetch bytes into `/pulls`) and the Swarm tests

Status: done on `claude/c2-slice8` (merged with main at 876b49a, slice 7).

- **Z5.** `fetch --report FILE` (slice 7's `write_report`) now works in Zigbox mode.
  `zigbox_fetch.Report` carries `peer_bytes` (by the place in the caller's peer list),
  `cached_bytes` (chunks the store already held) and `struck_peers` (a bad bundle or a chunk that
  failed its hash). The registry fallback adds `pull`'s blobs: `downloaded` and `resumed` count as
  `registry_bytes` (a resumed blob counts whole: Zigbox reports its size, not the part fetched),
  `cached` as `cached_bytes`. A tree already held whole returns at once and counts nothing.
- **Tests.** `zigbox_fetch.zig` asserts peer bytes, cached bytes and struck peers on the honest,
  corrupting and bad-bundle fetches; `fetch_cli.zig` tests `add_blob_bytes`.
  `agent_run.zig` now has tests (and is in `tests.zig`): `node_images` (the `Shell.images`
  choice: chunk directory, else Zigbox store, else fake) and `Swarm.zigbox_store`, which takes an
  `Environ` now and is tested with `XDG_DATA_HOME` in a scratch directory.
- **The supervisor passes `--report`.** `zigbox_supervisor.fetch_argv` adds
  `--report <state dir>/containers/<name>/pull.json` (it makes the directory), the file the agent
  already publishes to `/pulls` (agent.zig `publish_pulls`). Unit-tested as argv only. Trap: in
  Zigbox mode nothing removes `containers/<name>/` when the container goes; slice 7's agent drops
  a pull record it cannot read or publish, not a stale one.
- **Not covered:** the pull-fallback bytes against a real registry (only the sorting of blobs is
  tested); `run` itself (it needs a `std.process.Init`; its `Shell` line is `node_images`, tested);
  a process-level test of the supervisor's fetch (no KVM here, `zigbox-smoke` not extended).
