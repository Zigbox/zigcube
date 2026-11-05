# The X.509 parser has two profiles: `cluster` and `foreign_server`

*Decided 2026-11-04, by the slice (mTLS client slice 1, review finding M1).*

The review asked that a server leaf from another CA verify under a pinned anchor. The usual case is a leaf that OpenSSL made. The cluster's own parser must not loosen to accept one. So `x509.zig` has two profiles, and every caller names its profile:

- **`cluster`** covers the certificates this cluster's CA writes, and nothing else. A certificate is one of three kinds, its extensions come in one fixed order, and its bytes are exact. Anything else is refused, including the extra extensions a stock tool adds. "Parse, then write again" must give back the input, and the fuzzer checks this.
- **`foreign_server`** covers a server leaf signed directly by a pinned Ed25519 anchor.
  - It allows any issuer and subject Name, a serial of up to 20 bytes, the key identifiers, and extensions in any order.
  - It refuses an extension that appears twice, an unknown critical extension, a CA certificate and a leaf without serverAuth.
  - It requires exactly one DNS name or SPIFFE ID.
  - It still takes DER only and Ed25519 only.

Reasons:

- A strict profile is what keeps the cluster's parser small enough to fuzz against a writer and an independent oracle. Widening it for one case would lose that for every certificate.
- A second profile, with its own near-miss table and its own fixtures, keeps the wider surface in one place a reviewer can read.

The decision 2026-11-04-in-house-tls-review-before-c6.md says only the certificates Zigcube issues are accepted. This decision widens that for one case: a server leaf under an anchor the operator pins. Client and workload certificates are still accepted only from this cluster's CA.

Where: `src/x509.zig` (`Profile`, `parse_profile`, `verify_foreign_server`), `src/x509_foreign_test.zig`, `src/testdata/x509/gen.sh`, docs/mtls.md.
