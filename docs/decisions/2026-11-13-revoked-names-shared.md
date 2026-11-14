# Node and client names share the `revoked` file

*Decided 2026-11-13, by B7 slice 2 (the brief says revocation reuses the file by name).*

The server's `<state dir>/revoked` holds names, one per line, and refuses them for every kind it
issues: the peer credential, the node certificate and the client certificate.

- A name is refused whatever its kind. A node and a client called `ops-1` cannot be told apart
  in the file, so revoking one revokes both. Names are cheap; choose distinct ones. A per-kind
  prefix would change the file's format, which C2 fixed.
- The file is read at start, as before. `ca issue-client` reads it on each run, so a client
  name listed there is refused at once (ZC-E0807, whose summary still says "a node": its text
  is unchanged in this slice).
- Refusing a certificate already issued, at the handshake, is slice 3's (the API over TLS).
  Until then a revoked client's certificate lapses within `x509_leaf_ttl_ms_max` (7 days), and
  a node's within the credential's day.

Where: `src/peer_ca.zig`, `src/server_issue.zig`, docs/peer.md, docs/mtls.md.
