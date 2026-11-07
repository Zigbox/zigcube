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
  - `overran`: several nodes read the registry and **every** registry pull's span
    (`finished_at_ms - started_at_ms`) is at least the cap. The elected node is the shortest of
    them, since a waiting node's span is its wait plus its own pull. Passes, and the transcript
    prints the elected pull's span, the cap and why the other nodes pulled.
  - `repeated`: several registry reads although some pull finished inside the cap, or a record
    has no times. Fails, labelled "a duplicate pull", so a failure from an overrun is told apart
    from a real bug. An unmeasured run is strict.
  - `broken`: no registry read, or a node with no bytes at all. Fails.
- #93 (zigbox-smoke `fetch.log` silent): the fetch's progress line is now time-driven. It is
  written at most every `fetch_progress_ms` (10 s) from the first clock read or sleep of the
  fetch, not only on a peer chunk answer, and says elapsed time, chunk requests, bytes from peers
  and from the registry, the last source and the peers' non-chunk answers. No new code, limit or
  default: the constant and the line existed. The smoke's 120 s deadline is the harness's, not the
  fetch's, so no timeout code applies.

Where: docs/demos/c2.md (step 1), docs/agent.md (`fetch.log`), `src/demo_c2_check.zig`,
`src/fetch_cli.zig`.
