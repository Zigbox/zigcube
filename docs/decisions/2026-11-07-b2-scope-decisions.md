# B2's scope decisions (supervisor, 2026-11-07, under the owner's instruction)

The owner told the supervisor to make sane assumptions and document them. These are the
supervisor's answers to the owner decisions in [../briefs/b2.md](../briefs/b2.md). The brief is
written to them.

1. **Naming.** The hardening release stays **B2**, the owner's own word. The Botpike sequence in
   [../briefs/botpike-first-customer.md](../briefs/botpike-first-customer.md) moves up by one:
   - the relay becomes B3;
   - workload identity becomes B4;
   - signed images becomes B5;
   - placement by tenant becomes B6;
   - API identity becomes B7.

   That file is renumbered and says so. Decisions, retros and B1's brief written before this date
   keep the old numbers, because they record what was said then. These still use the old numbers
   and are follow-ups, to be renumbered by whoever next edits them:
   - `docs/briefs/mtls-client.md`;
   - `docs/peer.md`;
   - the comments at `src/x509_identity.zig:3` (B3, now B4) and `src/x509.zig:612` (B6, now B7).
2. **Retries and idempotency** (RB-S4, RB-S9).
   - **A late `POST /v1/jobs` retry.** Some retries arrive after `submit_by_ms`. If the job still
     exists and the spec matches, the answer is 200 with the existing job, not 410. ZC-E0134 (410)
     stays for a job that no longer exists, because it was retired or never created.
   - **Order of `env` and `labels`.** Both compare as maps: by key, independent of order.
   - **Duplicate keys.** A duplicate key in either is a validation error. Slice 3 uses the
     existing validation code if one fits. If none does, it asks before registering one
     (AGENTS.md).
3. **Cancel during a partition** (RA-S1, #142, #143). J6 keeps its fence term, and this is
   deliberate. A partitioned node cannot learn of a cancel. The node's self-fence is the bound
   that holds. A cancel's effect is therefore bounded by `ttl − fence_margin` plus the usual stop
   time. Slice 1 still fixes the J6 failures the fleet found, if they exceed that bound.
4. **The admission window** (the first half of RA-S4, and RA-S5). It is documented as **72 to
   73 h**. The reason is granularity: admissions are counted in hourly buckets, and the current
   hour's bucket is partial. The window does not change in B2, because B2 is a hardening release.
5. **mTLS.** Its fixes are in B2, as slice 6.

Decision 4 is read as fixing only the window's stated span. The second half of RA-S5
is different. A bucket in the future, left by a clock that was stepped forward, is never pruned,
and a clock stepped back folds into it. That is a defect, not a choice of window, so slice 3 still
fixes it.
