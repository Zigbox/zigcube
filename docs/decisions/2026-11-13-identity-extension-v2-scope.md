# The client's scope is version 2 of the identity extension

*Decided 2026-11-13, by B7 slice 2 (the brief fixes the field; this records its bytes).*

A `client` certificate carries its scope in Zigcube's identity extension, so the server needs
no table of clients: the certificate is the whole grant.

- Version 1 stays the `workload` form (labels). Version 2 is `SEQUENCE { INTEGER 2,
  ENUMERATED scope }`, exactly `30 06 02 01 02 0A 01 0s`, with `jobs` = 1 and `admin` = 2.
  Any other value, length or trailing byte is refused (ZC-E0809), like every cluster-profile
  byte.
- Each kind has exactly one version: `workload` must carry 1, `client` must carry 2, `node` has
  no identity extension at all. A version on the wrong kind is a near miss with its own row.
- A scope is a closed enum, not a string, so a future scope is a new value and an older server
  refuses it rather than reading it as something it knows.

Where: `src/x509_identity.zig` (`Scope`, `encode_client`), `src/x509.zig`, docs/mtls.md.
