# Backoff after a failed fetch (ZC-E0601), C2 slice 6b S6

Date: 2026-11-04. Supersedes "No backoff after ZC-E0601 (S6): a gap" in
`2026-11-04-fetch-fixes-part4.md`.

## Decision

The capped exponential backoff lives in the supervisor (`fake_supervisor.zig`), not in
`replica_controller`. The controller still replaces a replica whose fetch failed at once (blame
`fetch`, not `user`); the replacement's supervisor waits before it fetches.

- The wait after n consecutive failed fetches is `base * 2^(n-1)`, capped:
  `fetch_backoff_base_ms` 1 s doubling to `fetch_backoff_cap_ms` 5 min.
- The streak is a process fact on the node: `<state-dir>/fetch-streak.json` (failures, time of
  the last one, per digest). A success clears it. It holds no intent, so it fits the rule that a
  node's state dir keeps process facts only. A clock that went back is not trusted (wait left is
  bounded by the schedule).
- The wait is slept in `fetch_backoff_slice_ms` (100 ms) slices and ends early as `signaled` when
  the supervisor gets SIGTERM, so a stop during a backoff is a stop, not a failed start.
- `FetchFile` carries `state_dir` and the base and cap, so tests use short ones.

## Why not the controller

The controller has no clock anchor for a per-service retry (it would need a record in the store
and a `Run.wake_at_ms` per service: a store/record change that C1's conformance suite covers).
The failure is node-local (a registry or peer path from this node), so a node-local streak is
the right scope. The cost: a replica placed on another node starts its own streak.

## Tests

`fake_runtime_test.zig`: backoff growth, agent restart mid-fetch, SIGKILL of the fetch process,
stop while fetching. `fetch_backoff.zig`: schedule and cap, clock going back.
`FakeRuntime.stop_impl` now sends TERM to a fetching supervisor before it kills the group.
