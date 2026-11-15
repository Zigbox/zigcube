# The in-house TLS server gains a public mode on the edge; its review moves before 0.6.0

*Decided 2026-11-15, by the owner (C5 brief, Q2: option A, with a caveat); recorded by the
supervisor's docs session.*

This is the decision `2026-11-13-in-house-tls-server.md` asks for before any widening. It adds to
that file and to `2026-11-04-in-house-tls-review-before-c6.md`, which otherwise still hold.

- **Approved.** `tls_server.zig` gains a `Public` mode: no CertificateRequest, a P-256 chain from
  a public CA (Let's Encrypt), the certificate chosen by SNI, ALPN `http/1.1`, ECDSA P-256
  CertificateVerify. It is used **only by the edge's listeners on :443** (and :80, which serves
  plain HTTP for ACME challenges and the redirect, no TLS). Nothing else may use it: the API and
  mesh listeners stay mTLS, and B7's `Browser` mode is unchanged.
- **The external review moves from before C6 to before 0.6.0**, since C5 is the first time the
  server faces the internet.
- **The owner's caveat: the adversarial Fable release review of 0.6.0 counts as that outside TLS
  review.** So 0.6.0's release gate includes a reviewer on Fable who reviews the TLS server
  explicitly: `tls_conn.zig`, `tls_server.zig` and the edge's public mode, with the fuzzers,
  teeth and interop results in front of them. The release PR quotes that review's verdict on the
  TLS server separately from the rest.
- Any further widening (another group such as X25519MLKEM768, HelloRetryRequest, RSA, another
  suite) still needs a decision of its own.

**Open for the owner** (recorded, not decided here):

- Whether the Fable reviewer is one of the two release reviewers AGENTS.md requires (which says
  "two independent Opus reviewers") or a third. This file assumes a third, so AGENTS.md's rule is
  unchanged.
- Whether the review before 0.6.0 also discharges the C6 prerequisite of
  `2026-11-04-in-house-tls-review-before-c6.md`, or C6 needs another one for what it adds.
  This file assumes it discharges it for the code as it stands at 0.6.0, and that C6's own
  widenings bring their own decision.

Where: `docs/briefs/c5.md` ("Public TLS", "Ship gate"); `docs/supervisor-handoff.md` (release
prerequisites).
