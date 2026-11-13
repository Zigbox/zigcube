# B5 slice 1: signature bounds, the request bound, and what Zigbox does not export

Date: 2026-11-13. Proposed by the B5 slice 1 implementer; the supervisor decides each point below
in review (AGENTS.md: bounds and new codes are the supervisor's).

## Context

B5 slice 1 (`docs/briefs/b5.md`) puts `signatures` in the job body and judges them at
`POST /v1/jobs` with Zigbox's `verdict.judge`, under a policy file named in the server's
configuration. The pin moved to Zigbox `aa4d64c`, which carries `pub const trust`
(`docs/decisions/2026-11-12-zigbox-exports-trust-surface.md`).

## Decisions (proposed)

1. **The brief's bounds stay: 4 envelopes of at most 2048 bytes.** Zigbox's are wider:
   `signatures_per_tree_max` is 8 and `envelope_bytes_max` is the base64 of a 64 KiB statement
   plus 512 bytes. The exports decision said to ask if they differ. They differ, but the brief's
   are a strict subset, asserted at compile time in `src/job_trust.zig`, so every line a job may
   carry is one Zigbox reads and `Record.add` cannot run out of room. Measured with Zigbox's own
   `dsse.sign` on this pin, a tree-only line is 612 bytes and a manifest-bound one 768
   (`src/job_trust.zig`, "a signed envelope fits", holds a line to half the bound), so four tree
   or manifest signatures fit with room. What does not fit is a statement carrying a
   provenance record; provenance is a non-goal of B5. Raising the bounds later is additive.
2. **`job_request_bytes_max` grows by 16 KiB, to 425,984 bytes.** It was
   `6 * job_input_bytes_max + 16 KiB` (409,600), which left no room for the envelopes: a job with
   a full input and four full envelopes would be `413` ZC-E0108 although the brief admits it. The
   bound adds `2 * job_signatures_max * job_signature_bytes_max`: an envelope is printable ASCII,
   so JSON escaping (a `"` or `\` becomes two bytes) at most doubles it. This is a user-visible
   bound: the slowest client a full body allows within `http_idle_timeout_ms` goes from about
   40 KB/s to about 42.6 KB/s. Alternative: keep the bound and say that a job with a full input
   cannot also carry full signatures.
3. **`job_run_bytes_max` stays 16 KiB.** The envelopes count toward it, as the brief says
   (`check_run_size` measures `signatures` with the rest). Four 2048-byte envelopes escaped can
   take 16 KiB alone, so a job with long `command`, `env` and full signatures is refused by
   `check_run_size` (`400` ZC-E0130). Real lines are far shorter (point 1), so the brief's
   "ask first if 16 KiB is too small" has not been triggered.
4. **No new code.** Malformed `signatures` (count, length, not printable ASCII, or under a policy
   not a DSSE envelope Zigbox reads) is ZC-E0130 naming the field; a bad `trust` entry or policy
   file is ZC-E0106; a refusal is Zigbox's `ZBX-E0905` (or `ZBX-E0906` when a policy's
   provenance requirement is not met) with `403`.
5. **The refusal's text is mirrored, not shared.** Zigbox's run gate builds its E0905 diagnostic
   in `src/trust/diagnose.zig`, which imports the host and is not exported. Zigcube's
   `job_trust.refusal` writes the same cause lines (`reason_text` is copied from Zigbox) through
   `zigbox.diag.Diag`. A gap to report to Zigbox: exporting the pure part of `diagnose.zig` would
   let both share it.
6. **What is judged.** Only a new job: a retry of a stored job (the `200` same-spec path) keeps the
   answer it had, and `signatures` is part of the spec compared. Under a checking policy the
   image must be a tree (`b3:` and 64 hex digits); otherwise the refusal is E0905 with "not a
   tree". The binding is the `source`'s pinned manifest digest (its last 64 hex digits); with no
   `source` there is no binding, so only tree-only lines count.
7. **O3 (the resolve call).** Still open; the brief's default stands
   (`docs/decisions/2026-11-12-o3-assumed-botpike-runs-zbx-pull.md`): no resolve call.

## Consequences

The pin is a Zigbox `main` commit, not a release; before B5 ships, it moves to the release that
carries the export (0.5.1 or later), as the exports decision says.
