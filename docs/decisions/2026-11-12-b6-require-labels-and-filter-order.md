# B6 slice 1: how `require` meets node labels, and where the filter sits

Date: 2026-11-12. Status: decided by the implementer inside the brief; the owner may overrule.

- **Labels.** Node labels stay `[]string`. A word `key=value` is a pair `require` can match; the
  first word with that key is the node's value. `exclusive=K` is the reserving label. No new
  agent field and no new record version.
- **Exclusive at registration.** `exclusive=K` must name a `K` the node carries exactly once
  (`ZC-E0104`, no new code). A node may carry several `exclusive` words; each must be satisfied.
- **Filter order.** readiness, then require/exclusive, then fit. The brief says "before fit": the
  filter also follows the readiness checks so a hold can say "no *ready* node has tenant=acme".
- **Empty `require`** is stored as no `placement`, so the same job is one job (200, not 409).
- **Services** have no `placement` in `POST /v1/apply`; the generic unknown-field refusal
  (`ZC-E0104`) already applies, so no new refusal was added.
- **Teeth.** `scheduler.weaken_for_test` skips a rule in test builds only; each placement test
  reruns weakened and must fail.
