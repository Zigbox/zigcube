# demo-c2 "registry once" tells a slow elected pull from a duplicate pull

*Decided 2026-11-07, by the supervisor (issue #162); implemented in B2.*

On 4b97e69 the elected node's registry pull took 35.6 s on a slow CI runner, over the O5 wait cap
(`fetch_peer_wait_ms`, 30,000 ms). The other two nodes timed out and went to the registry, the
designed fallback, and demo-c2's step 1 ("registry read once") failed
(docs/demos/notes/2026-11-07-demo-c2-registry-once.md).

## Decision

- The cap stays at 30,000 ms. A product bound is not raised to absorb CI slowness.
- Step 1 stays strict, with one measured exception. `registry_read` (`src/demo_c2_check.zig`)
  classifies the pull records of the tree:
  - `once`: one node read the registry and every other node took bytes from peers. Passes.
  - `overran`: several nodes read the registry, exactly one of them is the elected node, its own
    pull record spans (`finished_at_ms - started_at_ms`) at least the cap less
    `holding_visible_lag_ms` (2,000 ms: `agent_resync_ms` + `fetch_peer_poll_ms`; a waiter sees the tree
    only after the elected node's next publish and its own next poll, so an elected pull a little
    under the cap is still a correct overrun; the cap itself is unchanged), and every other registry
    reader waited the cap out. The elected node is the one whose `fetch.log` says "pulls it from
    the registry first (O5)"; a waiting reader's `fetch.log` says "no peer came to hold the tree
    in N ms" with N at least the cap. A pull record starts when the registry pull starts, after
    the O5 wait (which is in the fetch, before the supervisor's pull), so a span never includes
    a wait and cannot tell which node was elected. Both facts come from each node's own log, so
    the VMs' clocks are never compared. Passes; the transcript names the elected node, its pull,
    the cap and each reader's waited time.
  - `repeated`: several registry reads without that evidence: no single elected node, an elected
    pull inside the cap or without times, a reader that did not wait out the cap, or missing log
    lines. Fails, labelled "a duplicate pull", so a failure from an overrun is told apart from a
    real bug. An unmeasured run is strict.
  - `broken`: no registry read, or a node with no bytes at all. Fails.
- #93 (zigbox-smoke `fetch.log` silent): the fetch's progress line is now time-driven. It is
  written at most every `fetch_progress_ms` (10 s) from the first clock read or sleep of the
  fetch and during O5's wait, not only on a peer chunk answer (a request in flight can delay it by
  up to `fetch_request_timeout_ms`), and says elapsed time, chunk requests, bytes from peers
  and from the registry, the last source and the peers' non-chunk answers. No new code, limit or
  default: the constant and the line existed. The smoke's 120 s deadline is the harness's, not the
  fetch's, so no timeout code applies.

Where: docs/demos/c2.md (step 1), docs/agent.md (`fetch.log`), `src/demo_c2_check.zig`,
`src/fetch_cli.zig`.
