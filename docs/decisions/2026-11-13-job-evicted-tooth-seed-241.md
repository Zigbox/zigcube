# The `job_evicted` tooth moves from seed 186 to seed 241

Date: 2026-11-13. Status: implementer's decision (fix of #225); no check weakened.

The fix of #225 (a wait while fencing is a pause, `2026-11-13-fence-wait-is-a-pause.md`) changes
what an agent does while fencing, so it shifts the simulated world, as #205 did
(`2026-11-11-job-evicted-tooth-sparse.md`). `sim-c1-teeth-job_evicted` at seed 186 (300
operations, `--c1`) then passed: the tooth made no run fail, 0 of 1.

Searched with the fault on, seeds 187 to 246 (three processes, stopped at the first hit):
189 failed J8 "a run is still open long after its deadline" and 225 failed J6, both other
symptoms, so not this tooth's; seed 241 failed "J8: a run that no node started was still open
long after its start_by_ms". With the fault off (`sim_c1_evict_world_main`, the fix on) seed 241
passes at 300 operations, `--c1`. The tooth's range, its canary (`241+1@300`) and the README row
move to 241; the tooth stays sparse and a change to the agent can move it again.
