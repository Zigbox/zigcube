# The node's own check (B5 slice 2)

*Decided 2026-11-13, by the slice (B5 slice 2), within the brief's fixed decisions.*

- **Where the check sits.** `refused_by_trust` (`src/agent_jobs.zig`) runs in `begin` after the
  deadline check (`past_bound`) and before the input fetch and `Runtime.start`. A refused run
  fetches nothing and starts nothing: over the fake runtime no supervisor is spawned and no
  container directory is made (`src/fake_runtime_test.zig`).
- **The ending.** The agent reports `stopped` with exit kind `refused` and the ZBX-E0905/E0906
  diagnostic; the job controller maps it to `failed`, cause `refused` (`map_ending`). No new ZC code.
- **The Zigbox import** happens in the supervisor (`supervise-zigbox`, `import_signatures` in
  `src/zigbox_supervisor.zig`), not in the agent: the supervisor is what opens the node's Zigbox
  store, right before `start_with_image`. The envelopes travel in `Runtime.Spec.signatures` and
  `spec.json`. A refused import is Zigbox's own ZBX-E0909 in the failure record (a start failure),
  so no ZC code was needed. The fake and simulated runtimes ignore the envelopes.
- **Wording.** Zigbox exports `trust` without `trust/diagnose.zig`, so `trust_refused`'s refusal
  words are mirrored in `refusal_words`. Gap reported to the owner: exporting it would remove the copy.
- **agent-smoke** restarts the agent with `--trust-policy` only at its end: a policy that asks for a
  signature refuses every image that is not `b3:` and 64 hex digits (`no_tree`), and the fixture's
  `b3:51aa9c03` is not, so the earlier steps run without a policy. The trust step writes its own
  images file (the fixture's two and the signed tree) and a policy trusting key 1 of
  `src/job_trust_fixture.zig`.

- **Upgrade order: server first.** The new exit kind `refused` (`/observed`), the job cause
  `refused` and the node record's `trust_policy` are additive members, but a server of slice 1 does
  not know the kind `refused`, so a new agent reporting one to an old server would be refused.
  Upgrade `zcube-server` first, then the agents. `spec.json` gains `signatures` (default empty);
  the agent and its supervisors are one executable, so they never disagree.
- **`Runtime.Spec.signatures`** is an additive member of an approved contract (HANDOFF's **Ask
  first**): the brief asks for the import on the real runtime, which has no other path to the
  envelopes. Flagged for the supervisor in the slice report.

- **Found, not fixed: a restart under a live lease publishes nothing new.** The agent renews its
  remembered lease and does not register again, so `/nodes/<node>.trust_policy` (like `capacity`
  and `agent_version`, before this slice) keeps the first registration's value until the lease
  ends; `zcube why node` lags a changed policy, though the agent enforces it at once. A fresh
  registration would move the tenure, which fencing compares: reported to the supervisor
  (`docs/agent.md`, "Known limits"). agent-smoke checks the policy by its effect for that reason.

Where: `docs/agent.md` ("The node's trust policy"), `docs/api.md` ("The node's own check"),
`docs/keys.md`, `docs/cli.md`.

## Handoff

Done: the check on both runtimes, the refused ending through the watch, `zcube why job`/`why node`,
the console's cause text, the import, the tests named in the brief, and agent-smoke's two jobs.
Not run here: the Zigbox import path (needs `ZCUBE_REAL_HOST=1`, KVM and GHCR; `demo-b3`'s world).
Next: B5's next slice per `docs/briefs/b5.md`.
