# The node certificate rides on the peer credential

*Decided 2026-11-13, by B7 slice 2.*

- **Same key, same life.** The `node` certificate is over the node's peer key and lives exactly
  as long as the credential issued with it: the server issues both in one call
  (`POST /v1/agent/nodes/{node}/credential`, field `node_certificate`, hex DER), so renewal is
  the credential's renewal and there is no second clock to keep.
- **Required.** The agent refuses an answer with no `node_certificate`, or with one for another
  node, key, kind or CA, and stores nothing. An agent of this slice therefore needs a server of
  this slice: the agent API is not versioned. Upgrade the server first. An answer with no
  `node_certificate` says so, and the agent keeps the credential it holds (review fix,
  decisions/2026-11-13-node-cert-bootstrap.md).
- **Stored as `node.crt`,** PEM, mode 0600, written after `ca.pub` and before `peer.cred`, so
  `peer.cred` is the last file of a set. A mismatched `node.crt` means the agent holds nothing and
  joins again, and a damaged one is the same as a damaged credential. A missing one beside a
  valid `peer.cred` keeps the credential: the agent logs the gap once, and the next renewal
  brings the certificate.
- **Checked at the renewal time** (the credential's midpoint), not at the node's now, so a node
  whose clock is a little off still accepts a fresh answer.
- **The client key format.** `ca issue-client` writes the key as PKCS#8 PEM (RFC 8410), the
  form openssl and the JDK read, not the hex seed of `peer.key`, because stock clients use it.

Where: `src/agent_api.zig`, `src/agent_peer.zig`, `src/pem.zig`, docs/api.md, docs/agent.md.
