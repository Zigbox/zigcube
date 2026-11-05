# O5: one node pulls from the registry first, the rest wait for a whole tree

*Decided 2026-11-05, by the fix implementer of demo-c2 step 1 (run 41959826512); for review.*

demo-c2 step 1 failed because nothing implemented O5 (docs/briefs/c2.md, owner 2026-11-03).
Started at the same time, every node's Zigbox-mode `fetch` found no peer that held the tree,
raised ZC-E0601 and exited 3, and each supervisor then pulled the whole image from the registry
(three times 43,273,982 B). That ZC-E0601 was the documented behaviour (docs/swarm.md, "The
Zigbox store path", item 5), not a second bug.

The fix:

- **The rule is in the core.** `fetch_plan.start` (wasm-clean) gives the decision from this
  node, the tree, the fetching nodes, whether a peer holds the tree, and the clock:
  `peers`, `registry_first`, `waited`, or `wait{until}`. `registry_rank` is the first 8 bytes of
  BLAKE3(node ‖ 0 ‖ tree); ties go to the lower name. sim-swarm's "start" operation and a unit
  test check exactly one registry puller.
- **The fetching nodes are `/assigned/<node>/<id>` joined to the image of `/replicas/<service>/<id>`.**
  They are read once per fetch. A node that cannot read them counts itself the only fetcher, so
  it does not wait. This is the behaviour from before O5.
- **The wait ends when a peer's `/node-store/` record lists the tree in `trees` and has a `peer`
  address. The chunk filter does not end it.** A Zigbox peer serves a tree only as the bundle of
  a whole tree, so a filter that claims some of its chunks is not enough. The wait polls every
  `fetch_peer_poll_ms` (1 s) for at most `fetch_peer_wait_ms` (30 s).
- **In Zigbox mode the designated node exits 3 with a note and no ZC-E0601.** The registry
  fallback is the supervisor's pull, so this is the fastest way to start it, and it is not a
  failure. In dir mode the plan goes to the registry itself, because there is no peer to wait
  for.

Trade-off: if the designated node is slow, or never gets the assignment, each of the others loses
up to 30 s before its own pull, but none of them pulls twice. Adding the "start" operation also
shifted sim-swarm's random stream, so a fleet seed filed before this change replays a different
run.

Where: `src/fetch_plan.zig` ("Who pulls from the registry first (O5)"), `src/fetch_cli.zig`
(`begin`, `fetching_nodes`, `peer_holds`), `src/constants.zig` (`fetch_peer_poll_ms`),
`src/sim_swarm.zig` (`check_start`), docs/agent.md, docs/swarm.md.
