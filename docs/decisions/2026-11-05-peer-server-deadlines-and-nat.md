# Peer server: sends never block, and per-source limits fit a cluster behind one NAT

*Decided 2026-11-05, by the slice (C2 release-review fixes; supervisor to confirm).*

**Sends.** The peer stream's reads and writes never block: `peer_stream.read_exact` and
`write_all` use `recvfrom`/`sendto` with `MSG_DONTWAIT` (and `MSG_NOSIGNAL`), the peer server
accepts with `SOCK_NONBLOCK`, and `peer_stream.connect` leaves its socket non-blocking (the fetch
client's registry reads and writes loop on `EAGAIN`). Before, a blocking `write` after `POLLOUT`
could wait for the reader without bound whenever the free send buffer was smaller than a record
(a small send buffer under memory pressure, or a small peer window bounding the segment size),
so a partitioned fetcher or a zero-window client held a serving slot past `peer_reply_ms` and
`Server.stop` waited on it. The test reproduces that with a 4 KiB `SO_SNDBUF` on the listener and
a 4 KiB receive buffer on the client; with the old send path it fails, freed only when the client
closes.

**Limits.** Every peer of demo-c2 arrives from 10.0.2.2 (QEMU's host forward), as nodes behind one
NAT address do, so the per-source bounds were a cluster-wide bound: one unfinished handshake and 16
per 10 s. A refused connection is a bare close, which the fetcher counts as a timeout, three of
which strike the peer and send the fetch to the registry. Now:

- unfinished handshakes per source: `peer_handshakes_pending_per_source_max` = 8 (of 32 links);
- handshakes per source per window: `peer_handshakes_per_source_max` = 256 per 10 s, which bounds
  unauthenticated public-key work at about 25 handshakes a second per address;
- serving slots per authenticated node name: `peer_connections_per_node_max` = 2 (of 4); the next
  is told 503 (busy), which the client backs off on and never counts as a strike.

A retry-later answer to a refused handshake was not added: a refusal comes before any key is
exchanged, so it could not be authenticated, and changing the handshake's first reply is a wire
change. The client still cannot tell a refusal from a cut (docs/peer.md, "Does not give").

Where: `docs/peer.md` ("The peer server and the fetch worker", "Rate limit"), `src/constants.zig`,
ZC-E0808.
