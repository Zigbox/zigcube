# Zigbox exports a pure trust surface for B5

Date: 2026-11-12. Decided by the supervisor under the owner's standing "make sane assumptions"
rule.

## Context

B5's brief says both checks (the server at admission, the agent before a run) call Zigbox's
`verdict.judge`, so they ask the same question in the same way. The pinned Zigbox (v0.5.0,
`4b3f6f9`) exports only `zigbox`, `zigbox_package` and `zigbox_vm`. Of the trust code,
`zigbox.zig` exposes only `store.export_trust`, `store.import_trust` and `store.prune_trust`;
`src/trust/verdict.zig`, `policy.zig`, `dsse.zig`, `statement.zig` and `record.zig` are private
imports. Zigbox `main` is the same. B5 slice 1 stopped there without writing code.

## Decision

- Zigbox adds `pub const trust` to `zigbox.zig`, exporting the pure parts needed to judge:
  policy parsing, the verdict, DSSE and statement parsing, and whatever record types the verdict
  takes. The parts that touch the host or the store (`host`, `store/fs`, `store/layout`) stay
  out. The exported parts must compile for `wasm32-freestanding`, so Zigcube's core can call them;
  Zigbox adds a compile check for that.
- Zigbox's verdict takes caller-supplied scratch space (no 6 MiB static `record.Work` inside the
  core), or the export documents the size so Zigcube's host can supply it.
- Zigcube does not copy the files. A copy would drift from Zigbox's the first time either changes.
- Zigcube moves its pin to the Zigbox commit that has the export, in B5 slice 1's PR. That PR
  merges only after the B3 tag (no B4, B5 or B6 code merges before it). Before Zigcube ships B5,
  the pin moves to the Zigbox release that carries the export (0.5.1 or later).
- B5 slice 1 checks that Zigbox's `envelope_bytes_max` and `signatures_per_tree_max` agree with
  the brief's `job_signature_bytes_max` (2048) and `job_signatures_max` (4). If they differ, it
  asks first.

## Consequences

B5 waits for one small Zigbox slice. The export becomes part of Zigbox's library surface, so
Zigbox's M8 "In the library" section gains it.
