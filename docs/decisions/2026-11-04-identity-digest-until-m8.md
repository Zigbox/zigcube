# Workload identity carries the image digest; the signer joins it with Zigbox M8

*Decided 2026-11-04, by the owner ("All as recommended", on the four contradictions the mTLS brief's Q8 found between it and the SPEC; `docs/briefs/mtls-client.md`, Q8, on `claude/mtls-client` at c0e2056).*

SPEC C4's acceptance says "A workload's identity changes when its digest changes, so a grant can be scoped to signed versions". The certificate's private extension carries the image's 32-byte BLAKE3 tree digest, so identity already changes with the digest. What it cannot yet say is who signed that version, because signatures do not exist until Zigbox M8 (signing and provenance).

- **Until M8:** the certificate carries the digest only. A grant can be scoped to an exact digest, but not to "versions signed by key K".
- **With M8:** the extension gains the signer's key ID, which is the full Ed25519 public key (the M8 owner answers). That makes a new extension version. The parser keeps accepting the old version until its certificates have expired; the C4 brief says for how long.
- C4's acceptance criterion for signed versions is not met until then. The C4 brief must carry it as open, not as met.
