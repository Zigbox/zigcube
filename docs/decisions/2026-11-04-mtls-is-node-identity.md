# Control-plane identity is mTLS with X.509, not WireGuard

*Decided 2026-11-04, by the owner ("All as recommended", on the four contradictions the mTLS brief's Q8 found between it and the SPEC; `docs/briefs/mtls-client.md`, Q8, on `claude/mtls-client` at c0e2056).*

SPEC C4 leaves this open: "mTLS per connection, or identity carried at the WireGuard layer?". It is now settled for the control plane: the server and every agent and workload client authenticate with mTLS, using Ed25519 X.509 certificates in the format of `docs/briefs/mtls-client.md` (a SPIFFE ID plus a private extension). This follows the owner's earlier "mTLS before C5", and the contract Botpike acknowledged: an Ed25519 server certificate signed by one pinned Ed25519 anchor.

WireGuard is not ruled out for the data plane (workload-to-workload traffic between nodes). If it comes, it carries traffic, not identity: a peer's identity is still its certificate.

The SPEC (Part II, C4) still lists the question as open. The live design doc needs the same change, and `docs/SPEC.md` in Zigbox follows at its next snapshot.
