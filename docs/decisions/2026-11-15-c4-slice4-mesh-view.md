# C4 slice 4: the agent's mesh view and the runtime seam

Date: 2026-11-15. Status: implementer's decisions, for the supervisor's review.

## What was decided

- **The agent reads a view, the server does not push rules.** `GET /v1/agent/nodes/{node}/mesh`
  serves `mesh_plan.input_for` of one snapshot (services, and the replicas the node's rules depend
  on, with readiness and endpoints). The agent plans it with the same `mesh_plan.plan` the server
  and the simulator use, so there is one rule-maker. The read is per step; a failed read holds no
  replica back (empty rules, replaced at the next good read).
- **Rules are sent whole, once per change.** `agent_mesh.Sent` keeps the hash of the last rules
  per replica (a ring of `agent_node_replicas_max`), in memory: a restarted agent sends each
  replica its rules once more, which the supervisor takes as the same.
- **The port is kept in a label** (`zcube.mesh-port`), so it survives an agent restart, and the
  free port is the lowest of the range no container of the node holds.
- **The endpoint's host is the advertised peer address's host** (C2's chunk server). No advertised
  address, no mesh. `--runtime zigbox` runs no mesh: its runtime refuses a mesh spec (ZC-E0711),
  and a Zigbox node may serve peers, so it would otherwise fail every replica start.
- **`--mesh-ports A-B`, default 30000-30999** (the brief's default). No minimum width is enforced:
  that would be a new user-visible bound, so it is asked, below.

## Open: a spent range churns (asked of the supervisor)

A replica the range has no port for, or whose port the supervisor cannot bind, fails to start
with ZC-E0710 (blame: environment). The replica controller replaces a replica whose start failed
through no fault of the user, so on a one-node cluster the replica is deleted and recreated in a
tight loop: the slice's test (a 1-port range, two replicas) saw about 16,000 store transactions in
5 simulated seconds. The default range cannot be spent (1000 ports, at most
`runtime_handles_max` = 512 containers). Options:

1. Refuse a range narrower than `runtime_handles_max` at start-up (a user-visible bound).
2. Hold a replica that failed with E0710 (a backoff in the replica controller).
3. Accept it: the range is the operator's, and the default is safe.

## Not done here

- A grant or readiness change does not wake the agent's watch; new rules reach a supervisor
  within the step period.
- The server reads the whole snapshot for each call.
