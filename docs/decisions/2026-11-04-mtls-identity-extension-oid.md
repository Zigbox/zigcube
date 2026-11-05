# The workload certificate's private extension lives under a UUID-derived OID arc

*Decided 2026-11-04, by the supervisor (Q4 of `docs/briefs/mtls-client.md`); generated in mTLS slice 1.*

- **OID.** `2.25.192541954756406065736426278304158759968`, the `2.25.<UUID as integer>` arc
  (ITU-T X.667) for UUID `90da3b4b-8df9-4f57-9af3-d569aaf6bc20`, generated once with a random
  (version 4) UUID. It needs no registration.
- **Use.** The non-critical extension of a workload certificate that carries image digest,
  placement epoch and labels (the brief, "Private extension"). Non-critical so a stock JVM or
  OpenSSL that does not know it still accepts the certificate.
- **Change.** A different OID (for instance a registered Private Enterprise Number) is a one-line
  change before anyone issues a certificate, an incompatible one after. The extension's own
  `version` INTEGER versions its value, not its OID.

Where: docs/briefs/mtls-client.md, src/x509_identity.zig.
