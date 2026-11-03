# C1 slice 9 review fixes: sim_fleet comments on a known failure once per commit and at most 4 times per issue per UTC day; the day's totals go to the tracker first, with seeds per issue

*Decided 2026-11-02.*

C1 slice 9 review fixes: `sim_fleet` comments on a known failure once per commit and at most 4 times per issue per UTC day; the day's totals go to the tracker first, with seeds per issue. A rate limit holds every write until GitHub's wait (capped at a day) is over, and failures seen only during the hold are reported when they recur. A 404/410 issue is refiled, a 403 one skipped. A missing state file is rebuilt from markers; an unreadable one is exit 2. No `ZC-` codes for `sim_fleet` (its errors print cause and fix; a subsystem for ops tools is the owner's call) and no in-process HTTP deadline (`run.sh`'s `timeout` is the deadline). A crashed `sim_cluster` range is replayed seed by seed with `--trace-steps` and each crash filed by its panic message (digits masked) and step.

Where: `docs/briefs/c1-9.md`, `ops/sim-fleet/README.md`
