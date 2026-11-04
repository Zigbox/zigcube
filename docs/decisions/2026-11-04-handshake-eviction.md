# Handshake links: evict the oldest stranger; no IPv6 prefix cap

Decision (2026-11-04, review follow-up of C2 slice 6b): when every handshake link is taken,
`peer_server.admit` shuts down the oldest link that has not authenticated and gives its link to
the newcomer. 32 silent sources can no longer keep honest peers out, and a newcomer is never
closed with no bytes (which clients counted as a timeout strike).

The fd is closed exactly once, by the link's own task; `Link.fd_state` keeps the evictor's
`shutdown` from touching an fd that task has already closed.

Not done: capping IPv6 sources per /56 or /48. The per-source limits already key on the /64;
with eviction a flood of /64s costs an honest peer at worst one retry, and a wider prefix would
risk merging unrelated hosts of one provider allocation. Revisit if the sim fleet or field use
shows a lockout.
