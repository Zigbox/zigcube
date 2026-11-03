# The peer handshake is SIGMA-I-style, and the CA has three rules (2026-11-03)

Decided in the review of C2 slice 6a.

## The handshake

The peer handshake (docs/peer.md) is a SIGMA-I-style exchange, not Noise. Consequences, so that
nobody claims more for it than it gives:

- The server's identity is revealed to an active attacker (it answers any well-formed M1 with its
  credential). The client's identity is revealed only to a server it has verified.
- There is no static DH and no chaining key. One ephemeral X25519 per side.
- The transcript signatures are transferable proofs, unlike Noise XX's, which are deniable.
- Authentication holds because each proof is sealed under the DH-derived key and signs a
  transcript hash that covers both ephemeral keys and the credential bytes.
- A side verifies the transcript signature before it judges the credential's CA, window and
  name, so a replayed old credential fails as ZC-E0804, not ZC-E0802.

## The CA

1. **Agents learn that the CA changed.** The CA key id rides on the chain pair every agent
   answer carries. An agent whose credential names another CA drops it and `ca.pub`, reports
   ZC-E0801 once and joins again.
2. **One CA per store.** `ca.key` is named `ca-<hash of the store identity>.key` and is never
   written to the store. A state directory or key file writable by group or others is refused
   (ZC-E0806). A lost key is remade silently only at a store's first start; otherwise the server
   stops (ZC-E0806) and `--new-ca` accepts a new CA.
3. **Issuance needs a live registration.** The request names the lease; the server issues only
   if the node's record is on it. The CA reads node and lease records and writes none. The API
   is unauthenticated, so revocation binds an honest node only until API auth lands.
