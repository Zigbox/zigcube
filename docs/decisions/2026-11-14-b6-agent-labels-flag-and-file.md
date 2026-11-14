# B6 slice 3: the agent's node labels, by flag and by file

Status: implemented on `claude/b6-slice3`.

## Context

Slice 1's review found that `zcube-agent` had no way to send node labels: the `exclusive` check
was reachable only through a raw `PUT /v1/agent/nodes/<n>`. The supervisor ruled (2026-11-14)
that the agent takes labels both from a flag and from a ZON configuration key, documented in
docs/agent.md and docs/keys.md, and left open whether one wins when both are given or a
conflict is refused.

## Decision

- `--label KEY=VALUE`, repeatable, and `.labels = .{ "KEY=VALUE", ... }` in the `--config` file.
- **A conflict is refused, not settled.** Every other setting follows "flags win". Labels do not:
  if both give labels and the two sets differ, the agent exits with `ZC-E0505`, cause "the node's
  labels are given by --label and by .labels in the file, and they differ", fix "give the labels in
  one place". The same set in another order is accepted. A label decides which tenants' work a
  node runs and whether it is reserved, so an operator who edits the file while a unit file
  still passes flags should hear about it before the node runs another tenant's job, not learn a
  precedence rule afterwards.
- **The agent is stricter than the server**, at start-up: each label is `KEY=VALUE` with a
  non-empty key, printable, at most 128 bytes, no key twice, at most 8; and `records.node_labels_problem`
  (an `exclusive` naming a key the node carries exactly once) runs before the agent dials the
  server. All of it is `ZC-E0505` (the agent's configuration), so no new code is registered.
- **The bounds are the server's.** The 8 labels and 128 bytes the agent API already admitted
  (a private `node_labels_max` in `agent_api.zig` and `check_text` with the label byte bound) moved
  to `constants.zig` as `node_labels_max` and `node_label_bytes_max`, which both sides use. No
  bound or default changed, so the supervisor was not asked.
- **Relabelling is a reinstall** (as slice 2 recorded): the agent sends labels when it registers
  a new tenure. Slice 3 recorded that a restart resuming the lease kept the old labels silently;
  the review fixes below refuse that start instead. The documented ways are to stop the agent for
  one lease ttl, or to empty its state directory, and start it with the new labels. Documented in docs/agent.md ("Running it") and docs/keys.md (`/nodes/<node>`).

## Added in the slice 3 review fixes

- Both sets are checked on their own (`check_labels`: format, duplicates, `exclusive`) before
  they are compared, so equal length and one-way inclusion mean the sets are equal.
- Label keys longer than `label_key_bytes_max` (32) are refused at start-up (`ZC-E0505`).
- The agent records its labels in `lease.json`. A start with other labels while the recorded
  lease would be resumed (same boot, not fenced, before its fence time) is refused with
  `ZC-E0505`, whose fix says to stop the agent for one lease ttl or empty `--state-dir`
  (supervisor's ruling: no new code). A lease file without labels, from before this change,
  starts as before.

## Not done (gaps to report)

- `zcube get nodes` does not show labels; `zcube job get` does not show `placement`; `zcube job
  run` has no flag for `placement.require`. demo-b6 reads labels with `GET /v1/list` and posts jobs
  with `POST /v1/jobs`.
