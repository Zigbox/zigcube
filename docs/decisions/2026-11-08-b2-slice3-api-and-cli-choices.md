# B2 slice 3: choices made while fixing the API and CLI findings

Status: **adopted** (B2 slice 3, 2026-11-08). No new code, no changed default or status.

- **Watch (RA-S3/RB-S5).** `held` holds a watch only when it read no events, its bookmark has
  reached the head, and the caller asked to wait. A watch that is behind the head returns at once,
  even with no events, because the events were all filtered out of the batches it read.
- **Limits (RA-N1).** Zigcube had no replica bounds to reuse, so `constants.job_limit_*` mirror
  Zigbox's runtime bounds (cpu 10 to 1,024,000 millis, memory 4 MiB to 2^40, pids 1 to 4,194,304):
  Approved by the supervisor under the owner's standing "make sane assumptions" rule: this refuses at submit what the runtime would refuse at start anyway, so no job that could run is newly refused. A job outside them would be refused when it starts, long after it was accepted. If the
  supervisor wants other values this is one block in `constants.zig` and one table in docs/api.md.
- **Oversized value (RA-N4).** ZC-E0207 with a cause naming both sizes, not a new code; the
  explanation text and the errors site say so.
- **Parse failures (RB-N2).** Distinct cause text under ZC-E0104. std.json reports a string and a
  negative number for an integer field alike, so those share one sentence.
- **Resume line (RB-S13).** On stderr, not stdout or in the JSON, so the output schema does not
  change. The arena of a round is freed after a round that succeeded; after a failure it is kept,
  because the report may point into it and the command ends.

- **Follow-up.** Service apply (replicas) does not check `limits` against these bounds; this slice does not add it.
