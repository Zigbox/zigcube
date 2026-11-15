# B5 slice 4 fixes: the review of demo-b5

Status: built and rehearsed in the cloud container; demo-b5 itself **not run** (no KVM there).
This applies the slice 4 review (two reviewers). It supersedes nothing in
`2026-11-13-b5-slice4-handoff.md` except where it says so below.

## Rulings

- **Job record, not assignment (accepted).** "An assignment written straight into the store" is
  still a job record written with `job_api.create` and `.trust = null` while the server is
  stopped (`src/demo_b5_inject.zig`). The server's controllers then make the run and the
  assignment, and the agent refuses it. A forged assignment would only test the forgery. The
  reviewers accepted this, and the demo document says so.
- **A job's `submit_by_ms` is Unix time.** `post_job` used `host.now_ms()`, which is time since
  boot, and the server refused every job with ZC-E0134 before the trust check. The body is now
  built on `std.Io.Clock.real` (`job_body`), and a test checks that `submit_by_ms` falls within a
  minute or so of the real clock. `demo_host.now_ms` says it is for durations only.
- **Each refusal is checked for its own reason.** At the server (403) and at the agent (`failed`,
  cause `refused`, `status.diagnostic`), each case must give ZBX-E0905 and a cause with that case's
  words. Unsigned gives "nothing has signed", the stranger's key "the policy does not list that key",
  and another tree "it is about another tree" (`inject.Refused.words`). A test runs
  `job_trust.admit` on each case and checks that each refusal carries its own words and no other
  case's. So a check that matched only the code would not pass a refusal for the wrong reason.
- **Step 4 is rehearsed on FakeRuntime: agent-smoke step 9.** The agent runs with
  `--trust-policy`, and the server is restarted with a trust policy. Three jobs are refused at the
  server with 403 and nothing is stored. Then the server is stopped, the same jobs are written
  into its SQLite store with `inject.inject`, and the server is started again. The agent must end
  each one `failed`, cause `refused`, with its own reason, and none of their commands may run (a
  file their commands would append to still holds only the signed job's line). Swapping two
  cases' reasons makes the step fail.
- **The node has a Zigbox policy, so the import really runs.** The slice 4 handoff said the guest's
  `--trust-policy` made the agent run `zbx trust import`. It does not. `import_signatures` runs
  only when the node's own Zigbox policy file (`/etc/zbx/policy.zon`, or the user's
  `zbx/policy.zon`) asks anything of a run. `guest.sh policy` now also writes the same policy
  where the agent's environment finds the user's file. After the signed job runs, `guest.sh kept`
  checks two things: the agent logged no "signatures were not kept" line (ZBX-E0909), and the
  node's own `zbx trust export` lists the tree's signatures. Either failing is a demo miss. The
  signer's zbx has its own `XDG_CONFIG_HOME` and does not read that file. Zigbox's library start
  has no trust gate of its own, so the file changes only whether the agent imports.
- **"No container" has a positive control.** The listing must show `signed-job`. The Zigbox
  runtime has no delete, so the signed job's directory is still there when step 4 looks.
- **CI routing.** `src/demo_c2_check.zig` is imported by `demo_c2_steps.zig`, so it now selects
  demo-b3 and demo-b5 as well as demo-c2, with a row in `ci-changes-test.sh`.
- **The guest script's fake zbx replays the real one.** `ops/demo-b5/testdata/` holds output
  captured from the pinned zbx 0.5.0 (built from `zig-pkg/`): a key's `.pub` file, a two-line
  `zbx trust export`, and the exit-1 refusal of an export from a store with no signature for the
  tree (which `kept` relies on). `test-guest.sh` says how they were made.
