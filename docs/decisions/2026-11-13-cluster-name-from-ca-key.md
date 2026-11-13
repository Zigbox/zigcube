# The cluster name in SPIFFE IDs comes from the CA key

*Decided 2026-11-13, by B7 slice 2. Open for the supervisor: see "The question" below.*

The brief writes `spiffe://<cluster>/node/<name>` and `.../client/<name>` but names no source
for `<cluster>`, and the server has no cluster-name setting. Slice 2 derives it:

- `<cluster>` is `zc-` followed by 16 hex digits of SHA-256 of the CA's Ed25519 public key
  (`peer_ca.cluster_of`).
- One CA names one cluster, and nothing new has to be configured or stored. The agent, which
  already holds `ca.pub`, works the name out the same way to check its node certificate.
- A certificate of another CA fails on the signature first, so the name adds no security of its
  own; it makes the identity readable and distinct in logs and in other tools' SPIFFE parsing.
- `--new-ca` changes the name, as it changes every credential: every agent joins again.

The question. The alternative is a `--cluster NAME` server setting (a new user-visible setting,
so it needs the supervisor's word): a readable name, at the price of one more thing to keep
equal on every host. Switching later changes every SPIFFE ID once, like a new CA.

Where: `src/peer_ca.zig`, `src/agent_peer.zig`, docs/mtls.md.
