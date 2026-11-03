# Slice 10c, review fixes: --mutate stale_history (get(key, rev) answers with the current value: read_at_wrong)

*Decided 2026-10-31.*

Slice 10c, review fixes: `--mutate stale_history` (`get(key, rev)` answers with the current value: `read_at_wrong`). A historical read whose bytes are not a token fails the run (every `/h/` value is the runner's, so it is a store bug, never "not ours"); a stage-2 coverage failure prints which coverage was missing and sets `Report.stopped`. **Not covered** by the fault runner, alongside leases: compaction racing writes (stage 2 runs after every writer has stopped), compare-and-set, create or version checks after a compaction, and watches opened after one. The proxied conformance suite's disturbance is driven by the wall clock, so `-Dseed` does not replay its timing (the suite's own seed still applies).

Where: `src/store_faults.zig`, `src/store_mutant.zig`, `src/testing/history.zig`
