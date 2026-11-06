# The sim-c1 negative test for `job_created` moves to slice 5

Owner, 2026-11-06 (review of B1 slice 3, PR 112). The merged record
`2026-11-05-b1-controller-never-recreates-a-run.md` asks for a sim-c1 negative test: a controller
with the `job_created` rule off must fail the check "a run is created once" (I8a). Slice 3 has the
unit tests of the rule (and of its per-incarnation form) but not that simulator test, because the
simulator has no job workload before slice 5. **Slice 5 owns that test.** It lands with the
simulator's job workload and its `sim-c1-teeth` entry; the merged record is not edited.
