# A stop tells the relay through `relay.stop`

Date: 2026-11-16. Context: the 0.5.2 release review, MUST B (PR #272).

## Problem

A run's relay is stopped by its supervisor, and the supervisor does that only once it has reaped
the command (`zigbox.wait` returns in `supervise-zigbox`, `child.wait` in the fake supervisor).
The agent's stop does not go through the supervisor: `ZigboxRuntime.deliver` signals the
container's PID 1 and `FakeRuntime.stop_impl`/`signal_impl` signal the command. A command that
ignores or handles TERM therefore keeps a working relay, and every open connection through it,
for its whole grace (up to 60 s), against B4's bound that a cancel ends the run's connections
within `relay_cancel_ms_max` (100 ms). The simulator's R7 checks the intended behaviour (connections
end once the supervisor is told to stop), which the real runtimes did not implement.

## Decision

Before either runtime signals a running container it creates an empty `relay.stop` in the
container's directory (`fake_files.mark_relay_stop`). The relay already polls that directory every
`relay_poll_ms` for `relay.crt`; it now also looks for `relay.stop` (`Relay.watch`, set by both
supervisors for plain and TLS relays alike). On seeing it the acceptor sets `stopping`, shuts every
connection down and returns, closing the listener. The command is left to the runtime's signal:
the relay does not kill it, and `ended_early` is not reached. `Relay.stop` afterwards is safe.

If the file cannot be created the runtime sends KILL instead of TERM (no grace): a run whose relay
cannot be told is not left relaying. A Zigbox container with no launch directory has no supervisor
of ours and no relay, so it is signalled as before.

`relay.stop` is one of `agent_records.relay_files`, so a new launch of the name removes it.

No code is registered and no bound changes. The relay writes no `relay.log` line for this cut (no
existing code fits, and registering one needs the supervisor's leave).

## Tests

- `relay.zig`: "relay.stop in the container's directory ends every connection and the listener"
  (the connection reads an end within `relay_cancel_ms_max`, the port refuses).
- `fake_runtime_test.zig`: "a stopped run's relay ends at the stop, not when its command does"
  (a TERM-ignoring command, `stop` with a 60 s grace: the connection is closed while the command
  runs).
- `zigbox_runtime.zig`: "a stop tells the container's relay before it signals".
- `zigbox_supervisor.zig`: the relay watches the directory under both plans.

Each fails without the fix.
