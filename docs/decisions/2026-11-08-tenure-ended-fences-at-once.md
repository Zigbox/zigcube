# A job report answered ZC-E0510 fences the agent at once; revision 0 from the network is refused

Status: **adopted** (B2, 2026-11-08, issue #172). It corrects one sentence of
[2026-11-07-stale-job-observations-refused.md](2026-11-07-stale-job-observations-refused.md),
which stays as written.

**Correction.** That decision says a refused report "neither fences nor moves the heartbeat: the
agent cannot tell stale from tenure ended". Over the remote store the agent can tell: the server
answers a stale report `200 {"applied": false}` and a replaced tenure `503` ZC-E0510. `RemoteStore`
used to fold the second into `succeeded = false`, the same result as the first, so the agent
fenced only when its next heartbeat or lease timer found out. It now returns ZC-E0510 as an error
(`BackendFailed` with the code raised), and the agent's job commit (`agent_jobs.zig`, `commit`)
begins the fence on it, as `Agent.Pass.commit` does for any other write under the tenure. A report
the store refuses with `applied: false` is unchanged: dropped, counted, read again next pass. No
new code, bound or default; no `Store` change (the error and its diagnostic were already part of
the contract).

**Revision 0 from the network.** `RemoteStore.list_result` refuses a listed record whose
`mod_revision` is 0 (ZC-E0504, "the server listed a record that is not valid"), as it already
refuses one above the listing's revision. Revisions start at 1, and an `/assigned` entry's
`mod_revision` is the assignment epoch a report and a claim compare, so a 0 would have reached
`assert(subject.epoch > 0)` in `agent_jobs.zig` and crash-looped the agent. The assert stays: it
now rests on a checked value. `create_revision` is not checked: the replies of older servers and
the tests' fixtures leave it out.

**Check.** Tooth `sim-c1-teeth-job_refused_loop` (`c1_teeth.job_refused_loop`) makes each
`running` report name an assignment that is not the stored one, so the store refuses it and the
agent makes it again on every pass (refusing every report breaks J8 first, which hides the
count). It must fail J10's bound (`job_refusals_after_heal_per_node_max`, 8); 30 of seeds 1..40
at 100 operations do.
Before it, no tooth reached that count: `job_stale` trips J9 and J10 at rest. The unit tests that
fail without the fixes are in `agent_client_test.zig` (revision 0, ZC-E0510) and
`agent_jobs_test.zig` (the fence).

**Upgrade.** Agent only; the wire is unchanged.
