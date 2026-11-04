# Fetch fixes after the review of slice 6b part 4

Date: 2026-11-04.

## Concurrent fetches of one tree (S5): no lock

Two replicas of one image placed on one node start two `zcube-agent fetch` processes for the
same tree. `dir_images` writes every chunk and list as a random-named temporary file, synced and
renamed into a content-addressed name (`write_whole`), so both fetches write identical bytes
and the later rename replaces the earlier with the same content; a reader sees a whole file or
none. The cost is duplicate network work, bounded by the fetch deadline. A per-tree lock would
add a lock file that a killed fetch must not leave held, for no safety gain. Not added.

## No backoff after ZC-E0601 (S6): a gap

`replica_controller` holds a replica only when a failed start has blame `user`. A fetch that
fails is `Blame.fetch`, not the user's, so the controller deletes the replica and creates a
replacement at once: with the registry and every peer unreachable this repeats once per fetch
attempt (each bounded by `fetch_total_ms`, 30 min, or by a refusal, which is fast). No backoff
is added here because it is a controller change (a per-service retry clock in the store) outside
this fix list. It needs the owner's decision; until then an unreachable tree makes a replica
churn at the speed of the refusals.

## Peer address is published, not guessed

`/node-store/<node>` carries `peer`, the `host:port` the node's peer server listens on, set from
`--peer-listen` (empty when it serves none). The fetch reads it instead of `/nodes/.address`,
whose port is the agent's API port. A node without `peer`, with a bad name, an unusable address
or no filter is left out and counted in one line on stderr.

## Fetch limits

`fetch_candidates_max` (64) nodes are read, ranked by the chunks their filters claim, and the
best `fetch_peers_max` (16) are used; only `fetch_list_peers_max` (4) are asked for the chunk
list before the registry. One deadline covers both tries of a peer request, and
`fetch_total_ms` (30 min) covers the whole fetch (`error.Deadline`, ZC-E0601).
