# The mesh view may go stale while its read fails (owner chose C)

Date: 2026-11-15. C4 fixups of #263 (Review A, `src/agent_mesh.zig`, `plan_now`). Status: in
#263 the gap is recorded and nothing is built (option A for now, approved by the supervisor).
**The owner chose C (2026-11-15).** After S = `node_lease_ttl_ms` (10 s) with no fresh view,
the agent fails closed on inbound only, and warns with a new ZC-W05xx code, which the owner
approved with C. C is built in its own pull request, a follow-up to #263.

## What the agent does now

Each step, `plan_now` reads the node's view of the mesh (`GET /v1/agent/nodes/{node}/mesh`). When
that read fails it returns null. The read can fail on a timeout, or on a reply that
`input_problem` refuses, such as one from version skew during an upgrade. The failure is noted
(`note_enforce_failure`), `update` is not called, and every supervisor on the node keeps the
last rules it was sent.

Fencing does not bound this. The heartbeat still succeeds, so the node keeps its lease. Nothing
limits how long a revoked grant stays open on that node. The fix for #263's first MUST is separate:
it sends the rules when other stages of the step fail, but only when the view read itself works.

Relevant constants are `agent_resync_ms` (1,000), `mesh_revoke_ms` (1,000) and
`node_lease_ttl_ms` (10,000).

**Consequence: the brief's revocation bound (watch latency + `mesh_revoke_ms`) does not hold
while the node's `/mesh` reads fail and the server stays reachable.** sim-c4 does not test this
case. Its truth bound (2026-11-15-c4-m2-each-end.md) starts at the heal. Before the heal it
judges each supervisor only against the view it was delivered, and its world has no `/mesh`-only
fault.

## Options for the owner

- **A. No bound (today).** The node keeps its last rules for as long as the read fails.
  Availability is unaffected, and the revocation bound is lost while the read fails.
- **B. Fail closed after S ms without a good read.** S is measured from the last good read on the
  agent's monotonic clock. Each running replica is sent empty rules (no accepts and no
  listeners), and its full rules go back on the next good read. A natural S is
  `node_lease_ttl_ms` (10 s): I3 already accepts that bound for a node cut off from the server.
  The cost is that a fault on `/mesh` alone (a server bug, or schema skew in a rolling upgrade)
  takes down all mesh traffic on the node after S, while its containers keep running.
- **C. Like B, but inbound only.** After S, replicas are sent empty accepts and keep their
  listeners and destinations. Revocation is the half that matters for security, and outbound
  requests still meet each destination's own accept checks, which stay fresh on healthy nodes.
  The blast radius is smaller than B's.
- **D. B or C with a short S,** for example `3 * agent_resync_ms + mesh_revoke_ms` (4 s). This
  keeps revocation close to the brief's bound, but a slow server trips it falsely more often.

Each of B, C and D changes behaviour users can see. Each adds a bound to `constants.zig` and to
`docs/agent.md`, and probably a new warning code ("mesh view stale, rules dropped", ZC-W05xx).
The code also needs the owner's approval; without it the change would reuse the existing
enforce-failure note.

**Recommendation, which the owner took: C with S = `node_lease_ttl_ms`.** It matches the I3 bound the system already
accepts, it bounds the half that matters for security, and it does not cut outbound traffic to
healthy destinations. B comes next, if the owner wants the same behaviour in both directions.

The follow-up must also add a simulator fault that fails `/mesh` alone, with a tooth that leaves
the bound out, so the chosen bound is shown to hold and to have teeth.
