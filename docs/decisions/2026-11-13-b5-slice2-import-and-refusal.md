# The Zigbox import is for zbx only, and a refusal wins (B5 slice 2 review fix)

*Decided 2026-11-13, by the fix session for B5 slice 2's reviews, within the brief.*

- **Zigbox's library start has no trust gate.** `zigbox.start` and `start_with_image` judge
  nothing: the run gate (`trust/gate.zig`) is used by `zbx run`, build and compose only, and it
  is not exported. The brief's "Zigbox's own run gate then judges the run a third time" does not
  hold for Zigcube's path. A gap reported to the owner, not papered over: the agent's check
  (`job_trust.judge_run`) is the node's only check.
- **So the import serves `zbx` on the node, and only when that node asks.** `import_signatures`
  (`src/zigbox_supervisor.zig`) reads the node's zbx policy (system, then user, through the
  Zigbox host's file system, as the gate would) and imports nothing unless it asks for a
  signature or provenance; a policy it cannot read or parse counts as asking. Zigbox's import
  keeps a line the store already holds once (`.present`), so a routine rerun adds nothing.
- **Only the lines that counted.** The agent hands the runtime the lines that counted in its own
  verdict (`job_trust.counted_lines`), none without `--trust-policy`. A stranger's lines (the
  API's writes are unauthenticated) cannot fill a tree's record or the store, and a line Zigbox
  would refuse (another tree, a bad signature) cannot make it refuse the good ones with it.
- **A store that will not keep them never wedges a start.** Before, the ninth signature for one
  tree (`signatures_per_tree_max`), a full store (`trust_records_max`) or a missing store made every
  later signed run on that image fail ZBX-E0909 for good. Now any failure of the import is one
  stderr line from the supervisor, `ZBX-E0909` with its cause, and the run starts: the run was
  judged by the agent, and nothing downstream reads the store. No new code, no bound changed.
- **A refused run ends refused.** The agent judges a run before its start bound and on every path
  that would report it `not_started`, so a refusal whose report was lost, or that came after the
  bound, is reported again as `refused` and never ends `failed`, cause `deadline`.
- **`zcube why node` claims only what the store knows**: "registered with --trust-policy <path>:
  job runs (not replicas) are judged under the policy the agent read at its start", or
  "registered without a --trust-policy that checks: no job run is judged". The agent publishes
  the path only when the policy asks for a signature or a provenance (`policy.checks()`), so a
  policy that asks for nothing registers none rather than a claim. The path must be absolute
  (ZC-E0505 otherwise: it is published as typed). A restart under a live lease does not register
  again, so the record can name a policy the agent no longer runs with, the dangerous direction
  included (`docs/agent.md`, "Known limits").

Tests: `src/zigbox_supervisor.zig` ("runs signed past signatures_per_tree_max ..."),
`src/agent_jobs_test.zig` (the two refusal tests, each failing on the code before the fix),
`src/why.zig` ("why node names the policy path ...").
