# Placeholder `ZBX-` codes

HANDOFF has the fake runtime use "a placeholder `ZBX-` code agreed with the Zigbox side". At the
pinned Zigbox commit (`90b6f1c`) the registry has no code for a start that fails because an image
digest is not in the node's store, so Zigcube keeps one itself, in `src/runtime_codes.zig`, and
the simulated runtime raises it. `/v1/codes` and `/v1/explain` serve it beside Zigbox's own.

None at present. `ZBX-E0501` ("image not found"), which this file used to hold, became Zigbox's
`ZBX-E0410` ("no tree with that digest") when the pin moved to Zigbox 600939c, which registers it;
Zigcube's registry entry is gone and the codes API serves Zigbox's page. The mechanism stays in
`src/runtime_codes.zig` for the next code Zigbox lacks. Still unregistered: a code for `lost`
(the supervisor died, or the process vanished); the simulated runtime reports `lost` with no
diagnostic, which the contract allows.

## Codes `FakeRuntime` raises of its own (slice 6a)

`lost` has no `ZBX-` code yet, and neither does a command that cannot be run, so the real-process
`FakeRuntime` uses `ZC-` codes of the agent's range (`src/diag/codes.zig`). They travel in the same
diagnostic shape; when Zigbox registers the equivalents they move, as `ZBX-E0501` (now `ZBX-E0410`) did.

| Code | Blame | Summary | Raised for |
| --- | --- | --- | --- |
| `ZC-E0507` | environment | the agent can't start a container's supervisor | `start`: the host refused a process (also a recorded `start_failed` blamed on the host) |
| `ZC-E0508` | user | the container's command can't be run | `start_failed`: the program was not found or may not run; the replica is held |
| `ZC-E0509` | environment | the container's supervisor is gone | `ExitReason.lost`: no record of how the command ended |
