# The in-house X.509 and TLS code is accepted; an external review is a C6 prerequisite

*Decided 2026-11-04, by the owner ("All as recommended", on the four contradictions the mTLS brief's Q8 found between it and the SPEC; `docs/briefs/mtls-client.md`, Q8, on `claude/mtls-client` at c0e2056).*

The SPEC's risk table says, for identity and mTLS, "Reuse proven libraries … external review before C6". The mTLS brief writes the X.509 writer, the strict parser and the TLS 1.3 client in-house, on the Zig standard library only. That is because std's TLS client cannot answer `certificate_request`, and the no-third-party-dependencies rule stands.

The owner accepts this, because the scope is narrow:
- Ed25519 only.
- TLS 1.3 only, with one group (x25519) and one cipher suite (AES-128-GCM).
- Only the certificates Zigcube issues itself are accepted.
- The primitives are std's.

What stays from the SPEC is the review:

- **An external security review of the X.509 and TLS code is a C6 prerequisite**, like the Jepsen battery for C5 (`2026-11-03-jepsen-before-c5.md`). It is done by someone outside the project, against the code as it stands at C6. The C6 release notes cite it.
- Until then, the in-tree defences are the gates: the near-miss tables, the fuzzers with their teeth, the interop checks against openssl, keytool and the JDK (`zig build x509-format`), and two Opus reviews per release.
- Any widening of the scope above (another key type, another cipher suite, accepting certificates from stock tools) needs a decision of its own.

Where: `docs/supervisor-handoff.md` (C6 prerequisites); the C6 brief when it is written.
