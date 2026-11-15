# demo-c2 step 2 bounds the peer fetchers, not the registry reader

*Decided 2026-11-15, by the supervisor (option C of the demo-c2 failure on the C3 chain).*

On the C3 chain (CI run 43764638241, on 5d00e21; earlier on 07f3aa4, with the same byte count),
demo-c2's step 2 failed: "node1 transferred 43273981 B for v2 (at most 1048576)". It passes on
main.

## Root cause

- C3 rolls a service one replica at a time. python-app's first v2 replica is placed on node1
  alone, so `GET /v1/agent/nodes/node1/fetchers/<v2>` names node1 only. O5's `registry_first`
  (`src/fetch_plan.zig`) elects node1, and no peer holds v2 yet. The swarm fetch ends in
  ZC-E0601, and the supervisor's registry pull follows (ZC-W0603).
- node1 got v1 from its peers: the chunks and an imported image record, with no compressed
  layers. Zigbox's registry pull reuses only layers the node itself pulled from the registry, so
  node1 downloaded all of v2's layers (registry 43,273,981 B, cached 0 B).
- On main all three nodes fetch v2 at once. O5 ranks them by blake3(node, 0, tree), and for v2's
  tree node2 ranks lowest (node2 2.35e18, node3 9.73e18, node1 1.13e19). node2 read v1 from the
  registry, so its pull reused the base layers (registry 6,682 B, cached 43,267,299 B).

C3 broke no fetch, cache or placement rule. The gap, that a registry pull ignores the layers a
node holds as a tree fetched from peers, is on main too: main passes only because the hash elects
the node that read v1. That gap is Zigbox's and goes to the owner (option A). Changing O5's
election to work around it (option B) was rejected.

## Decision

- Step 2 bounds, at `v2_bytes_max` (1 MiB), each node that fetched v2 through its peers alone
  (0 registry bytes).
- The registry reader is judged as in step 1 (`registry_read`): one reader, or an elected pull
  that overran the O5 cap. The evidence is only the fetch.logs of the containers that run v2,
  since v1's fetch.logs stay on the node. Its registry and cached bytes are printed, so the gap
  stays visible in the transcript.
- This is a cut in the demo, not a fix. Once Zigbox's registry pull reuses layers held as a tree,
  step 2 should bound every node again, and a sim-swarm tooth comes with that fix.

Where: `src/demo_c2_check.zig` (`roll_pull`, `evidence_in`), `src/demo_c2_script.zig` (step 2),
docs/demos/c2.md ("Steps" item 2, "Deviations and cuts").
