# TLS client, part 1: what it leaves out

*Decided 2026-11-05, in slice 4 of docs/briefs/mtls-client.md; the owner may overrule.*

- **CertificateRequest is refused** (ZC-E0813), not answered with an empty certificate. Client
  authentication is slice 5; until then a server that asks is one we cannot satisfy.
- **The client never starts a KeyUpdate by itself.** `send_key_update` exists for the connection
  layer (slice 6), which knows when a key limit is near.
- **Only a DNS name is checked** against the server's certificate. SNI is always sent, so the
  ClientHello's size is not a constant.
- **Errors map to codes by cause**: ZC-E0818 for what we do not offer (HelloRetryRequest, version,
  suite, group, scheme), ZC-E0813 for malformed, out-of-order or unverified messages and for server
  alerts, ZC-E0815 for record-layer faults, ZC-E0816 for an end without close_notify, ZC-E0810 to
  ZC-E0812 and ZC-E0819 from `x509.zig` for the chain.
- **Test-only fault flags** in `tls_client.zig` (compiled in tests only) skip the CertificateVerify
  check, the Finished check or the EncryptedExtensions in the transcript, so a test can show that
  each check is what stops a bad server. The pin is covered by a certificate with a damaged
  signature.
