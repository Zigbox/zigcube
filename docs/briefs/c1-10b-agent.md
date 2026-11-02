# C1 slice 10b, agent side: an agent refuses an answer from behind

Parent brief: [c1-10.md](c1-10.md), 10b, third bullet. The server side (`VerifiedStore`,
`server_remember.zig`, `ZC-E0215`, `ZC-E0216`) is merged (PR #28).

## What

- **Every agent endpoint's answer carries `chain`**: `{"revision": R, "hash": "<hex>"}`, the
  store's `status` taken after the endpoint did its work (so it is at least as new as anything in
  the answer). Taking it after the work, from `status`, gives one rule for all seven endpoints
  (lists, transactions, leases, the watch), and on an honest store it never goes down across one
  agent's requests, which are sequential. A list's own `revision` or the watch's bookmark would
  not work: the bookmark can be below a report the agent has already seen acknowledged.
- **The agent sends what it remembers**: every request carries `?known=K` (its remembered
  revision, omitted while it remembers nothing), and when `K <= R` the answer's `chain` adds
  `"known_hash"`: the store's hash at `K`. Without it, a store that forked (a promoted replica
  that was behind) and then took more writes than the agent had seen would pass: its revision is
  higher. With it, the check is the server's: lower revision, or a different hash at the
  remembered revision. If the store has no hash at `K` (`NoHash`, `K` below the chain's start),
  `known_hash` is left out and the agent refuses it as unverifiable, as the server does.
- **`hash_at` on `RemoteStore` stays unsupported.** The agent core never calls it; the check is
  inside `RemoteStore`, on the same answer the core would act on, so there is no gap between the
  check and the answer, and no second round trip. A separate `hash_at` call would cost a request
  per step and check a different moment than the one acted on.
- **The check** is in `RemoteStore` (core, `agent_client.zig`): an answer whose `chain` is below
  the remembered pair, or whose `known_hash` differs from the remembered hash or is missing, is
  `ZC-E0215` (the server's diagnostic, worded for an agent: "this agent remembers ...; the server
  answered ..."), and the call fails before the reply is parsed for anything else, so the core
  acts on nothing from it. A missing `chain` is `ZC-E0504` (the agent and server must match).
  The refusal holds until an operator intervenes: the remembered pair does not move down.
- **The pair persists** in `AgentState` as the file `remembered` (put_atomic: temporary file,
  fsync, rename, fsync of the directory, as the agent's other files), saved when it advanced and
  at most every `verified_save_ms` (as the server does: a lagging copy is safe, only weaker), and
  at once the first time. It is loaded at start (`zcube-agent` and the simulation's restart). A
  state directory without the file (every agent before this slice) loads with nothing
  remembered. A file that does not parse stops the start with `ZC-E0216`.
- **The way out**: after `zcube store accept-rollback --confirm` on the server, the operator
  removes `<state dir>/remembered` and restarts the agent. The `ZC-E0215` fix line says so when
  an agent raises it. No new flag.

## Tests

- Core (`agent_client_test.zig`, a scripted transport): an answer at a lower revision is refused
  with `ZC-E0215` and the list it carries is not returned; the same revision with a different
  hash is refused; a higher revision with a different `known_hash` (a fork that grew) is refused;
  a missing `known_hash` is refused; normal progress advances the pair and sends `known`; the
  pair survives a restart through `SimState`; an old state without the file loads; a damaged
  file is `ZC-E0216`; a refused answer does not lower the pair.
- Server (`agent_api_test.zig`): every endpoint's answer carries `chain`, `known_hash` matches
  `hash_at`, and a `known` above the store's revision gets no `known_hash`.
- Over HTTP (`agent_remote_test.zig`): the existing tests pass unchanged with the check on.
- `sim-cluster` passes (it now saves and loads the pair across crashes); `agent-smoke`,
  `demo-c0` (SQLite and Postgres) pass.

## Non-goals

An agent-side `accept-rollback` command or flag; any change to `Store` or `Runtime`; the
decision record of a rollback (a known 10b gap); the 10d failover test.

## Review fixes (2026-11-02)

The supervisor's review of the first pass decided M1-M5 and L6-L11; what was done is in
docs/DECISIONS.md (row of 2026-11-02, "review fixes") and docs/agent.md, "The remembered pair".

**Cut (M3), a gap for the owner:** after `zcube store accept-rollback --confirm`, recovery is per
node: each agent that refused needs `rm '<state dir>/remembered'` and a restart. An accepted
rollback could travel in `chain` as `{from, to}`, and an agent whose pair equals `from` would
adopt `to`; not built in this slice.
