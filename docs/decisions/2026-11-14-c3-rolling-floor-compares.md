# C3: what a rolling retirement compares (TLA+ gap 1)

*Decided 2026-11-14, by the supervisor, on C3 slice 7's question; recorded for the owner.*

**Context.** A rolling rollout retires a running old replica only when
`up - 1 >= replicas - max_unavailable` (R1, the floor). The TLA+ model found that the replica
controller counts `up` on its read and commits later: a counted replica that stops, or whose node
is lost, in between makes the commit take `up` below the floor although the controller never
judged it so. The exact cure is to compare, in the retiring transaction, every key the count
rests on: the `/observed` record of each kept running replica the floor needs, and its node's
`/node-status`. A transaction holds at most `store_txn_compares_max` = 16 compares, and a
retirement already spends about 5 (the service, the rollout, the replica counter, the decision's
2) plus 2 for each replica it retires (record and report). So the exact proof fits while
`(replicas - max_unavailable) + distinct nodes of those replicas <= about 10`.

Waiting until it fits (a stall) never ends for a large service with a small `max_unavailable`
(replicas 50, max_unavailable 1 needs 49 compares and more), which are the services that need a
rolling update most. Raising the store's compare limit changes the store contract.

**Decision.**

1. When the exact proof fits in the batch, the retiring transaction compares the reports of
   `replicas - max_unavailable` kept running replicas and their nodes' status
   (`replica_controller.Run.expect_floor`).
2. When it does not, it compares as many kept replicas as fit, the lowest replica numbers first
   (the plan is sorted by number), with their nodes' status, and retires anyway when
   `up - 1 >= replicas - max_unavailable` on its own read, in the same transaction. It does not
   wait a pass.

Past the limit the floor is a decision-time property: the controller never itself takes `up`
below the floor on the state it read. A kept replica that dies between the read and the commit is
the same fault as one that dies just after the commit, which no compare can prevent.

**Consequences.**

- The reading of TLA+ finding 7 the code takes is "recheck": each pass recounts from the store,
  with the stored budget as a cap, and the retiring write compares the service, the rollout
  record, the replica counter, the retired replicas' records and reports, and the floor above.
- sim-c3's R1 judges this promise: at the head before the commit, a replica that is not running
  but whose report the transaction did not compare and that changed after every key it did
  compare is counted as running (`retirements_doubted` in the tally, `doubted=` on the report
  line). The `rollout_budget` tooth, a controller that retires below the floor on its own read,
  still fails R1.
- Unit witnesses (`src/rollout_controller_test.zig`): a kept replica reported stopped, and a
  pause, each written between the controller's read and its commit, fail the retirement; each
  test fails with its compare removed.
- Follow-up for the TLA repo (not changed here): the model's floor invariant is exact while the
  proof fits and decision-time past it, by this rule.
