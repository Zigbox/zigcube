# B5 keeps its own signature caps, below Zigbox's

*Decided 2026-11-12, by the supervisor (answers the "asks first" in
`2026-11-12-zigbox-exports-trust-surface.md`; no bound, default or code changes).*

**Question.** Zigbox's trust export (Zigbox PR #124) sets `envelope_bytes_max` = 350,040 and
`signatures_per_tree_max` = 8. B5's brief sets `job_signature_bytes_max` = 2048 and
`job_signatures_max` = 4. The earlier decision said B5 slice 1 asks first if they differ. They do.

**Decision.**

- Zigcube keeps 2048 bytes and 4 envelopes as its own admission caps. They bound what a job
  submission may carry into the store and the control plane, which Zigbox's limits do not
  consider; a 350 KB envelope per job is far more than a key-signed statement needs (an Ed25519
  DSSE envelope over an in-toto statement for one digest is well under 2 KB).
- Zigcube's caps must stay at or below Zigbox's, so anything Zigcube admits is something Zigbox's
  verifier accepts by size. B5 slice 1 adds a comptime assert:
  `job_signature_bytes_max <= zigbox.trust.limits.envelope_bytes_max` and
  `job_signatures_max <= zigbox.trust.limits.signatures_per_tree_max`.
- An envelope over 2048 bytes is refused at admission with the existing size code (ZC-E0130 naming
  the field and the bound), not passed to Zigbox to fail later.
- Raising either cap later is a user-visible bound change and asks the owner first.

## Consequences

B5 slice 1 need not stop on the mismatch. Keyless (certificate-carrying) envelopes, if ever
supported, would need a larger cap and a new decision.
