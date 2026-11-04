# Handshake links: evict an old stranger; no IPv6 prefix cap

Decision (2026-11-04, review follow-up of C2 slice 6b, revised by the follow-up review of 4077d90):
when every handshake link is taken, `peer_server.admit` shuts down the oldest link whose
connection is still a *stranger* (handshake not finished) **and at least
`peer_handshake_evict_min_ms` (750 ms) old**, and gives its link to the newcomer. 32 silent
sources can no longer keep honest peers out.

State: each link has one atomic `LinkState` (closed, stranger, authenticated, evicting, evicted).
The link's task moves stranger to authenticated by compare-and-swap; an evictor moves stranger to
evicting the same way. Whoever loses backs off: a task that loses closes as being evicted, an
evictor that loses looks again (another stranger, or none). An authenticated link is never
touched. The fd is closed exactly once, by the link's own task. `Server.evictions` counts
evictions; no log line was added (ZC-E0808 names a refused address, and an eviction has none
that DIAGNOSTICS.md describes without a new code).

Why a minimum age: oldest-first eviction under a sustained flood gives every honest handshake a
fixed lifetime. About 200 sources reach roughly 320 admissions a second, which evicts every link
within ~100 ms, so a peer with a round trip above ~65 ms never finishes.

What a newcomer can still see (it is closed with no bytes, which clients count as a timeout
strike, and tries again): every link is authenticated; every stranger is younger than the
minimum; the evicted task did not end within 500 ms.

Residual bound: a link is evicted only after 750 ms, so a flood evicts at most 32 strangers per
750 ms, and a handshake that finishes within 750 ms is never evicted by anything. A handshake
slower than that can still lose its link while a flood lasts; at most 32 admissions per minimum
age are possible, so the flood needs to outlast the peer's retries. The other limit is
`peer_limit`'s `table_full` refusal, which turns sources away once about 256 are tracked.

Not done: capping IPv6 sources per /56 or /48. The per-source limits already key on the /64, and
a wider prefix would risk merging unrelated hosts of one provider allocation. Revisit if the sim
fleet or field use shows a lockout.
