# The peer listener accepts any API-minted node name until mTLS

*Decided 2026-11-05, by the owner.*

Until mTLS lands, C2 ships with each node's peer listener accepting any credential the API mints,
so any node name. A peer can therefore claim to be any node. This is accepted because fetch trusts
a peer's bytes only against the full 64-hex digest, so a peer that lies about its name can waste
time but cannot plant content; and because mTLS, which binds a node's name to its certificate,
comes before C5.

When mTLS ships, the listener accepts only a certificate naming the node, and a new decision
replaces this one.

Where: [docs/demos/c2.md](../demos/c2.md), "Interim: peer listener credentials"; [docs/peer.md](../peer.md).
