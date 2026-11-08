# 2026-11-08: an unreadable report pins a cancel until it decodes or the node is lost (#190)

Decided by the supervisor, 2026-11-08.

**Problem.** In `judge_unreadable` (`src/job_controller.zig`), a run that is not yet `running`
and whose node report does not decode takes no new step while the node is alive: a cancel writes
its stop, but the run only ends once the node is judged lost. Both ways to reach it need corrupt or
skewed state (a report written by an incompatible agent, or damaged in the store).

**Decision.** Accept the pin and add no new bound in B2. The run waits until the agent's reports
decode again (its next report replaces the unreadable one) or the node is judged lost, which ends
it `failed unknown`. A timeout of our own would be a new user-visible bound for a state that
should not occur, and would end a run that may still be executing.

The `hold_unreadable_job` reason for a report now says what happens: "its report does not
decode; a cancel waits for a good one or a lost node". Existing tests already pin the
behaviour (`a running run whose report does not decode still takes a cancel and a lost node`, `a
claimed run whose report does not decode ends failed unknown when its node is lost`).

Where: the code is `judge_unreadable` and `hold_unreadable_report` in `src/job_controller.zig`.
