# 2026-11-05: the replica controller acts only on admissible observations (I3)

**Decision.** A replica controller pass classifies a replica from its observed report only if the
report is admissible (docs/authority.md §3): its tenure equals the node's current `/nodes/<node>`
mod_revision, its assignment epoch is current and `/node-status/<node>` is `ready`. A decision that
rests on a node being judged (lost, or a dead report with a tenure) compares that node's status
mod_revision and `/nodes/<node>` in the same transaction (`expect_node_judged`), so a node that
registers again between the read and the commit fails the transaction.

**Why.** Before this, the sim-c1 I3 check failed on seeds 105, 145, 166, 276, 300 and 306 of the
auto sweep (ttls 5250 to 9069, so not only inside #78's range). The controller code is identical on
origin/main; main's 400-seed 100-operation sweep did not reach it. Regression tests are in
`replica_controller_test.zig`; each failed before the fix.

**Classification.** Seeds 86, 180, 254 and 343 are not I3 failures: they are the busy loop of #78 at
ttls 5129 to 5959, fixed by the floor (lease-ttl-floor decision).
