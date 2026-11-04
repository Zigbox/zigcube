# The "failed command" line under a passing `zig build test` is not a failure

Decision (2026-11-04). The C2 slice 7 and slice 8 reports saw `check: PASS` over a log with
`failed command: .../test --seed=0x... --listen=-`. That is not a gate failure. The pinned build
runner (`lib/compiler/Maker.zig`, line ~2861 and `printErrorMessages`) prints a step's stderr
together with its `failed command:` line whenever the step's stderr is non-empty, whether the step
succeeded or not; `Step/Run.zig` sets the failed command before it knows the outcome. Reproduced:
a test that wrote to stderr made `zig build test` exit 0 and still print that line. Slice 8's
lying-peer tests print ZC-W0601 to stderr, which is the trigger. `zig build test --summary all`
(all steps succeeded) and the exit status are the verdict.

The gate itself is right: `check` cannot run after a failed dependency, and `run` fails any
non-zero exit or signal. `src/testing/check.zig` now has a test of that. A first attempt that
scanned stderr for `failed command:` was dropped: it fails the gate on exactly these passing runs.

Advice: a test that must print to stderr should be rare; when it does, expect this line.
Not found: any real intermittent failure (8 direct runs of the test binary and 3 `zig build test`
on main all passed), so the "no test named" failure from slice 7 is unexplained but is probably
the same line over a pass.
