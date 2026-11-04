# The workload SPIFFE ID is spiffe://<cluster>/service/<name>

*Decided 2026-11-04, by the owner ("All as recommended", on the four contradictions the mTLS brief's Q8 found between it and the SPEC; `docs/briefs/mtls-client.md`, Q8, on `claude/mtls-client` at c0e2056).*

SPEC C4 binds identity to the service name, and Zigcube's API calls workloads services (`docs/api.md`: `"subject": {"kind": "service", ...}`). The mTLS brief had `spiffe://<cluster>/job/<name>`. From now on the path is:

    spiffe://<cluster>/service/<name>

Here `<name>` is the service name. No certificate has been issued outside tests, so this changes no deployed format.

- The fix session for slice 1's review makes the change, before slice 2. It covers the brief, `x509_identity.zig`, the extension comment ("service or job" becomes "service"), the near-miss table, the goldens and the fuzzer.
- The label charset stays provisional until B1 fixes it.
- Another path kind, such as nodes or the server, needs its own decision. It does not reuse `/service/`.
