# A busy peer is waited for, within a bound; a failed fetch counts each peer's answers

Date: 2026-11-05. Decided by: the C2 fix implementer, at the supervisor's request (demo-c2 on #76).

## Context

demo-c2 step 2 failed on #76: two nodes fetched v2 from the node that had just pulled it, and both
ended in ZC-E0601 "a chunk could not be had from any source asked" with no other line. Busy
answers (#84's per-node serving limit, `peer_connections_per_node_max`) were suspected, but the
fetch never logged them, and a busy peer was given up after 4 × 250 ms.

The cause turned out to be elsewhere: a peer server's `ZigboxImages` lives as long as its
serving slot, and after its first walk of the store's roots it never walked again for a tree
another process (the supervisor's `zigbox pull`) added later, so it answered every chunk of v2
with "not found". `ZigboxImages` now lists the roots on a miss after a walk and walks again if
they changed (test "a tree another process added is served after the adapter has walked").

## Decision

- `fetch_busy_retries_max` (4) is replaced by `fetch_busy_wait_ms` (20 s): a request that is
  answered busy is asked again, the pause doubling from `fetch_busy_sleep_ms` (250 ms) to
  `fetch_busy_sleep_max_ms` (2 s), until the next pause would pass 20 s; then it is `.refused`
  and the plan takes the chunk from another source. Still no strike and no timeout.
  20 s is well under `fetch_total_ms` (30 min) and long enough for a serving slot to free
  (`peer_idle_ms` 2 s, `peer_reply_ms` 5 s), so a burst of fetchers queues instead of failing.
- Each peer's answers (busy, a status other than 200, no reply) are counted for the whole
  fetch, and a fetch that ends in ZC-E0601 logs one line per peer asked before it.

The per-node bound is unchanged. The client already holds at most one stream per peer
(`Net.conns`), within `peer_connections_per_node_max`; two fetch processes of one node toward
one peer can take both of that node's slots, and a third would now wait instead of failing.
