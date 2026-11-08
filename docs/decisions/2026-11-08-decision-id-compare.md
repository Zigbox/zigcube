# 2026-11-08: a decision's id is compared absent, and three batch bounds shrink (#177)

Decided by the supervisor, 2026-11-08 (option A of the choice put to them in #177).

**Problem.** `put_decision` wrote `/decisions/<id>` unconditionally. Two writers (or a restarted
instance whose counter began again in the same millisecond) could produce the same id, and the
second write would overwrite an audit record, which is meant to be immutable.

**Decision.** Every `put_decision` adds `batch.expect(/decisions/<id>, 0)`: the key must be
absent. A collision makes the transaction a conflict, the controller reruns the pass and draws a
new id. `decision_compares` goes from 1 to 2 (the id, and the summary's revision).

Rejected: reading the key first (B). It is not atomic with the commit, and it needed a new code.

**Bounds, before and after.** A transaction allows 16 compares (`store_txn_compares_max`), so the
batch sizes that hold decisions shrink. They are per-transaction sizes inside the control plane,
not user-visible limits; a pass with more work takes one more transaction.

| Bound | Before | After |
|---|---|---|
| `batch_replicas_max` (replica controller) | 3 | 2 |
| `hold_batch_max` (replica controller) | 3 | 2 |
| `observed_stale_per_txn` (node controller, derived) | 13 | 12 |

The comptime asserts in `controller.zig` and `replica_controller.zig` hold. The "one more replica
would not fit" assert is now stated in compares, the limit that binds.

Cost: a rare extra transaction under many simultaneous changes (see `docs/demos/c0.md`).
