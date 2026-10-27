# Placeholder `ZBX-` codes

HANDOFF has the fake runtime use "a placeholder `ZBX-` code agreed with the Zigbox side". At the
pinned Zigbox commit (`90b6f1c`) the registry has no code for a start that fails because an image
digest is not in the node's store, so Zigcube keeps one itself, in `src/runtime_codes.zig`, and
the simulated runtime raises it. `/v1/codes` and `/v1/explain` serve it beside Zigbox's own.

| Code | Blame | Summary | Raised by |
| --- | --- | --- | --- |
| `ZBX-E0501` | user | image not found | a start whose digest is not in the fixtures list |

**Not agreed yet:** the number (Zigbox's `05xx` is "registry and pull"; that is why this one is
`E0501`), the wording of the cause and fix, and a code for `lost` (the supervisor died, or the
process vanished). The simulated runtime reports `lost` with no diagnostic, which the contract
allows ("null means it truly does not know"), because there is nothing registered to say.

The code leaves `runtime_codes.zig` the day Zigbox registers it; the diagnostic's shape (a
`Diagnostic` with a `ZBX-` code, built from the JSON of DIAGNOSTICS.md) does not change.

## Codes `FakeRuntime` raises of its own (slice 6a)

`lost` has no `ZBX-` code yet, and neither does a command that cannot be run, so the real-process
`FakeRuntime` uses `ZC-` codes of the agent's range (`src/diag/codes.zig`). They travel in the same
diagnostic shape; when Zigbox registers the equivalents they move, as `ZBX-E0501` will.

| Code | Blame | Summary | Raised for |
| --- | --- | --- | --- |
| `ZC-E0507` | environment | the agent can't start a container's supervisor | `start`: the host refused a process (also a recorded `start_failed` blamed on the host) |
| `ZC-E0508` | user | the container's command can't be run | `start_failed`: the program was not found or may not run; the replica is held |
| `ZC-E0509` | environment | the container's supervisor is gone | `ExitReason.lost`: no record of how the command ended |
