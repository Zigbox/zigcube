# The peer handshake is interim; mTLS is the target

**Decided:** C2 slice 6a authenticates node-to-node traffic with the Noise/SIGMA-style handshake
of `docs/peer.md` over a credential signed by the control plane's CA. It is a stopgap. Mutual TLS
(X.509 certificates from the same CA) is the eventual target, because it is what operators,
proxies and audit tools already understand.

**Consequences:**

- Release documentation must say the handshake is interim and not a standard protocol. It has had
  a seeded fuzzer and teeth tests, not an outside review.
- The credential format, the CA key and the `revoked` file are the parts meant to carry over:
  moving to mTLS replaces the handshake and the encoding of a credential, not who signs or how a
  node is removed.
- Server-side TLS and mTLS support will be open-sourced before EC2 self-hosting: C5 at the latest,
  C4 if C4 picks mTLS for workload identity.
- Until the API has auth the credential endpoint is as open as every agent endpoint
  (`docs/peer.md`, "Trust model").

**Reversal:** replacing the handshake touches `src/peer.zig` and its callers only.
