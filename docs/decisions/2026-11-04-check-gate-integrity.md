# The check gate does not trust exit status alone

Decision (2026-11-04). `src/testing/check.zig`'s `run` now sends a child's stderr to a file, copies
it to ours, and fails the gate if the child exits non-zero or if its stderr holds a failed-step
report (`failed command: `, `error: the following build command failed`,
`test process unexpectedly`), even on exit 0. Its tests (`zig build test`) prove it, and
mutating the rule makes them fail.

Cause of the C2 slice 7 symptom (a `check: PASS` over a log with a `failed command: ... test ...
--listen=-`): not found. Ruled out: `check` cannot run after a failed dependency step
(Maker skips it); nested `run` already failed on any non-zero exit or signal; the Zig 0.17 runner
(`lib/compiler/Maker.zig`, `Step/Run.zig`) exits 1 whenever a step failed and has no retry;
tests spawn children with stdin and stdout ignored, so the `--listen=-` protocol is not written
to. The report line `failed command: zig test --listen=-` is printed for any failing test step,
including a test that fails by assertion, so the missing test name suggests a runner death with
no active test ("test process unexpectedly ..."), or a build whose log was merged with another.
Loops on main (8 direct runs of the test binary, 3 `zig build test`) never failed. Next step
if it recurs: the new gate prints the full stderr of the failing nested step; keep that log.

Trap found: a gate's own tests must not echo failure text on stderr (the build's stderr is
scanned by the gate above it); `run_echo(..., false)` keeps them quiet.
