# C3 starts beside the B track, in part

Date: 2026-11-13. Decided by: the supervisor, at the owner's request to run ahead.

Botpike's order (`2026-11-05-botpike-o1-o2.md`, O1) puts B1 to B7 ahead of C3's rollout, and the
Botpike input says C3's fleet slices can and should run beside the B track. Every C3 owner
question is answered (`2026-11-05-c3-owner-answers.md`).

## Decision

- **Start now:** C3 slices 2 (`test-store-faults` daily in the fleet), 3 (coverage feedback) and
  5 (keys, records and docs). Slice 1, the teeth canary, is already running in the fleet. Slice 6
  (`rollout_plan`, pure core) follows slice 5.
- **Wait for B6 to merge:** slices 7 and 8 (the rollout controller, the replica controller's
  budget, rollback). They change the replica controller and scheduler that B6 also changes.
- **Wait for slices 5 to 8:** slices 9 to 12 (health probes, the real probe, API/CLI/console,
  demo-c3).
- **Not started:** 13 to 16 (packages, macOS `zcube`, the release). They follow the owner's
  answers 9 and 10.
- Nothing from C3 merges to main before the b3 tag. After it, C3 work merges as it passes review,
  interleaved with the B track. Where they conflict, the B track merges first.
