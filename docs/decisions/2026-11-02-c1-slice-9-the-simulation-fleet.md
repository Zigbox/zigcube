# C1 slice 9, the simulation fleet: a failure's identity is a hash of the run kind, the failing check and the *step* of the run it failed at (faults, healed, convergence, end; sim_cluster prints it as a step: line), never the seed, commit or operation count, so one bug is one issue across commits

*Decided 2026-11-02.*

C1 slice 9, the simulation fleet: a failure's identity is a hash of the run kind, the failing check and the *step* of the run it failed at (`faults`, `healed`, `convergence`, `end`; `sim_cluster` prints it as a `step:` line), never the seed, commit or operation count, so one bug is one issue across commits. The reporter is Zig (`src/sim_fleet*.zig`, standard library only, TLS by `std.http.Client`) and reads `sim_cluster --shrink` output on stdin; the host loop is a short allow-listed shell script. Filed fingerprints live in a state file and are recoverable from a hidden marker in each issue body; seeds per day are counted there and posted as one comment per finished UTC day on a tracking issue. A comment, not a new issue, for a failure that has one, including a closed issue (that is how a regression shows).

Where: `docs/briefs/c1-9.md`, `ops/sim-fleet/README.md`
