# Supervisors of one node pull one at a time

*Decided 2026-11-12, by the B3 slice 4 fix implementer (no bound, default or code changes).*

**Symptom.** demo-b3: the bystander job and the hostile job use the same image, which the node
has never pulled (`learn` pulls into a scratch store). A job is `running` once the agent has
launched its supervisor, not once the container is up, so the hostile job's supervisor started
while the bystander's pull was still going. Both pulled the same blobs into Zigbox's store, one
renamed away the partial file of the other, and the second ended `start_failed` with
`ZBX-E0417 can't write the store: moving the blob into the cache failed (ENOENT)`, with no line
anywhere in the agent's log.

**Decision.**

- Zigbox's store takes one writer. The supervisors of a node now take turns on `pull.lock` in
  `<state>/zigbox/` (an exclusive file lock, released by the kernel if the process dies).
  `zigbox_image.start_with_image` takes it after the first `ZBX-E0410`, tries the start again
  (the supervisor before it has probably brought the tree), and only then fetches or pulls. A
  tree already in the store costs no lock.
- A supervisor that fails to start writes the one-line `zcube-agent: container NAME did not
  start: CODE summary: cause` to its stderr, which is now the agent's, as well as `failed.json`.
  A failure that lands after the agent stopped waiting used to leave nothing in the log.
  A failure inside the settle window is logged by both the agent and the supervisor.
- `job get` prints `why:` for a job that failed to start (docs/cli.md).

**Not done.** The demo still does not wait for the bystander's container to be up; the product no
longer needs it to.
