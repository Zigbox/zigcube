# Revoked names may name their kind

*Decided 2026-11-14, by the B7 slice 3 fix session (review SHOULD, "revocation namespace").
Supersedes 2026-11-13-revoked-names-shared.md.*

The server's `<state dir>/revoked` still holds one name per line, and a bare `NAME` still
revokes every kind of that name: the peer credential, the node certificate and the client
certificate. A line may now carry a kind:

- `node/NAME` revokes the node NAME only: its peer credential, its node certificate and its
  handshake on the API (ZC-E0807 when issuing, ZC-E0819 at the handshake).
- `client/NAME` revokes the client NAME only: `ca issue-client` and its handshake.

Why: with the API over TLS (slice 3) a revoked name is refused at the handshake. With names
shared, revoking a client `ops-1` also cut off a node `ops-1`, and nothing in the file could
say otherwise. The prefix keys the file by kind without changing any existing line's meaning,
so a C2-era file reads as before. Any other prefix (`workload/x`), an empty name (`client/`)
or a name that still holds a slash (`client/node/x`) does not parse, and the server does not
start (ZC-E0806), as for any other bad line.

Where: `src/peer_ca.zig` (`Revoked.Kind`, `contains`), `src/server_tls.zig` (`caller`),
docs/mtls.md, docs/peer.md.
