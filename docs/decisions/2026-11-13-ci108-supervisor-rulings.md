# Supervisor rulings at check-in 108 (2026-11-13)

Status: decided by the supervisor under the owner's standing instruction to make sane
assumptions and record them.

- **`probes_concurrent_max = 8` (C3 slice 9).** Approved. A node runs at most eight probes at
  once; the bound is enforced, tested and documented in the slice. Raising it is a new decision.
- **`-Dstore-faults-only` (C3 fleet fix, slice 2).** Approved as a new build option. It changes
  no existing default; it exists so a store-faults finding can be replayed exactly.
- **B6 slice 2, P1.** The brief's P1 (a service never stays on an exclusive node, at any
  revision, not only at placement time) stands. Narrowing it to placement time was not asked
  for. The fix session makes the replica controller move a service off an exclusive node on
  re-registration (`replica_controller.zig`, around line 297) rather than keep it, until the
  brief's P1 holds on every seed.
