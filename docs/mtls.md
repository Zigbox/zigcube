# Certificates and mTLS

This document describes how Zigcube makes and checks its X.509 certificates. The brief is
[briefs/mtls-client.md](briefs/mtls-client.md). Slice 1, the X.509 slice, is built. Slice 2, the
TLS 1.3 client, is not started.

## Certificates

All keys are Ed25519 and all encoding is DER. The writer is deterministic, the parser is strict,
and verification checks against one pinned anchor key. The code is in `src/x509.zig`,
`src/x509_der.zig` and `src/x509_identity.zig`. It is core code: it never allocates, never
reads a clock (the wall time is an argument) and never uses a randomness source.

### Two profiles

The decision is in decisions/2026-11-04-x509-two-profiles.md.

- **`cluster`** (`x509.parse`, `verify`) covers what this cluster's CA writes.
  - There are three kinds:
    - `ca`: BasicConstraints and KeyUsage.
    - `server`: BasicConstraints, KeyUsage, ExtKeyUsage serverAuth, and a SAN with one DNS name.
    - `workload`: BasicConstraints, KeyUsage, ExtKeyUsage clientAuth, a SAN with one SPIFFE ID
      (`spiffe://<cluster>/service/<name>`), and the identity extension.
  - Each kind has its extensions in a fixed order, and its bytes are exact. The issuer's CN is
    `zcube-ca-` followed by 16 hex digits.
  - A certificate parsed and then written again gives back its exact input bytes.
- **`foreign_server`** (`x509.parse_profile(..., .foreign_server, ...)`,
  `verify_foreign_server`) covers a server leaf signed directly by an operator-pinned Ed25519
  anchor, such as one made with OpenSSL.
  - It allows any Name, a serial of up to 20 bytes, key identifiers, and extensions in any order.
  - It refuses an extension that appears twice and an unknown critical extension.
  - It requires serverAuth, a leaf (not a CA), and exactly one DNS name or SPIFFE ID.

### Validity

A certificate is valid from `not_before - 60 s` (inclusive) to `not_after + 60 s` (exclusive).

- UTCTime is used through 2049 and GeneralizedTime from 2050. The parser accepts only the
  canonical form of each, with no second 60 and no day the calendar lacks.
- A leaf's lifetime is at most 7 days. A CA's, or a foreign leaf's, is at most 10 years.
- The decision is in decisions/2026-11-04-x509-validity-boundaries.md.

### Identity labels

A label key is at most 63 bytes and a value at most 256 bytes. There are at most 16 labels, and
together they total at most 256 bytes (decisions/2026-11-04-identity-label-bytes-256.md). They
are sorted by key, with no key twice.

## Tests

- **`src/x509_test.zig`**: the writer and parser, the time rows, and the identity labels.
- **`src/x509_near_miss.zig`**: one edit away from a good cluster certificate, with the exact
  error each edit must get.
- **`src/x509_foreign_test.zig`**: the `foreign_server` profile, run against fixtures that
  `src/testdata/x509/gen.sh` made with OpenSSL.
  - The fixtures are committed, and no test runs OpenSSL.
  - Rerun the script only to change a fixture, then commit every file it writes. It makes new
    keys and dates each time.
- **`zig build x509-format`**: openssl, keytool and others read the certificates the writer
  makes. It needs those tools, so it is not in `check`.
- **`src/x509_fuzz.zig`**: mutates good certificates of all three kinds, plus the foreign
  fixtures.
  - **Cluster profile.** Every result the parser gives must agree with an independent naive
    decoder, `src/x509_oracle.zig`. That decoder has its own TLV walker and its own checks.
  - **Round trip.** An accepted certificate must write back to its exact bytes.
  - **Foreign profile.** Only the unmutated fixture verifies.

### Replaying a fuzz failure

`src/fuzz_seeds.zig` runs both `x509_fuzz.zig` and `peer_fuzz.zig`.

- Each run has a master seed, and iteration `i` uses the `i`-th SplitMix64 output of that seed.
- A failure prints two lines that replay it:

```
x509 fuzz failed at iteration 812: OracleDisagrees
  replay the run:       ZCUBE_FUZZ_SEED=… ZCUBE_FUZZ_ITERATIONS=813
  replay the iteration: ZCUBE_FUZZ_ITERATION_SEED=…
```

To run long, set `ZCUBE_FUZZ_ITERATIONS=N` and run the test binary directly. Without
`ZCUBE_FUZZ_SEED` this takes a fresh seed from the OS. The run prints its seed first and a PASS
line last:

```
ZCUBE_FUZZ_ITERATIONS=20000 .zig-cache/o/<hash>/test --test-filter "x509 fuzz" | cat
```

## Diagnostics

| Code | Refused because |
| --- | --- |
| ZC-E0809 | malformed or outside the bounds; the field is named |
| ZC-E0810 | not signed by the pinned anchor |
| ZC-E0811 | expired or not yet valid; shows the window, the time now and the skew |
| ZC-E0812 | names another peer; shows both names |
| ZC-E0817 | an identity could not be issued |
| ZC-E0819 | issued for another role, such as a client certificate where a server's is needed |

For ZC-E0819, the fix is to give the peer a certificate issued for its role.
