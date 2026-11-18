# The `job_evicted` tooth moves from seed 241 to seed 284

Date: 2026-11-18. Status: implementer's decision (fix of the #237 review, PR #281); no check
weakened.

PR #281 changes how the server takes a registration (a registration on a lease older than the
key's is refused with ZC-E0205, and a same-lease, same-value registration is idempotent;
`2026-11-18-registration-lease-order.md`). That shifts the simulated world, as #205 and #225 did
(`2026-11-11-job-evicted-tooth-sparse.md`, `2026-11-13-job-evicted-tooth-seed-241.md`).
`sim-c1-teeth-job_evicted` at seed 241 (300 operations, `--c1`) then passed: the tooth made no
run fail, 0 of 1. It misses at c3258d3 as well as at the E0205 commit, so the shift came with the
PR's earlier registration changes, not with the choice of code.

Searched with the fault on, seeds 242 to 301 (three processes of twenty seeds): seed 284 failed
"J8: a run that no node started was still open long after its start_by_ms". With the fault off
(`sim_c1_evict_world_main`, the PR's server) seed 284 passes at 300 operations, `--c1`, 0 of 1.
The tooth's range, its canary (`284+1@300`) and the README row move to 284; the tooth stays
sparse and a change to the agent or the server can move it again.
