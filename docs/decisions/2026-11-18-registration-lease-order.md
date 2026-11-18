# A registration on an older lease is refused (#237)

Status: decided 2026-11-18 (takes PR #239 forward; the brief "correctness and evidence fixes for
0.6.0", item 1). PR #239's decision file, never merged, is folded into this one. The refusal's
code was revised the same day from ZC-E0510 to ZC-E0205 (see "Old agents").

## Problem

An agent grants a lease and registers on it. If that attempt is delayed on the wire, the agent
tries again on a newer lease and holds tenure. The delayed attempt then arrives, and a server
that accepts it moves `/nodes/<node>` onto the older lease, which nobody renews. The key vanishes
when that lease expires, the node is marked lost while its agent runs its replicas, and they are
replaced elsewhere (I1b). The register transaction compared nothing about the tenure it replaced.

Measured on the real system (zigcube-jepsen run 44232537976): an idle node was lost for 20.2 s;
the running case showed zero overlap. A second report, an idle node renewing the wrong lease
indefinitely, came from older code: the keepalive has checked since B7 slice 3 that the node's
key is on the lease it renews (ZC-E0205), so that agent now fences at its next renewal.

## Decision

1. **The lease order.** `PUT /v1/agent/nodes/{node}` reads the key. If it is on a lease newer
   than the registration's, the registration is refused (ZC-E0205, 503, no new code) and moves
   nothing. If it is on the registration's own lease with the same value, the PUT is a copy of
   the one that wrote it (a retried or duplicated request): it is answered with the key's
   revision and writes nothing, so the tenure its agent holds stays the key's (rewriting it
   would end that tenure and stop every container on the node). Otherwise the server writes in
   one transaction compared on the revision it read (0: absent). Within one server the read and
   the write are under the API's write lock, but the driver's `expire_leases` is not, so a lease
   that ends between them makes the compare fail, and the registration is refused (ZC-E0205)
   with the cause "the key /nodes/<node> changed between the server's read and its write".
   The compare also guards a second server on the store (C7); a newer registration refused
   because an older one committed between its read and its write is then the agent's to retry
   on its next step.
2. **Why the order is enough.** The #237 PUT is an earlier attempt, so its lease is older than
   the one the agent registered on next: lease ids only grow (SQLite `AUTOINCREMENT`, a Postgres
   identity column, the memory store's counter; a conformance test, and a SQLite test that
   deletes every lease, reopens the file and grants again), and an agent grants its
   lease before it sends. Every legitimate retry (a lost reply, a crash before the agent
   recorded the tenure, a server restart, a wiped state directory) carries a lease at least as
   new as the key's and is accepted at once.
3. **Nothing from the agent.** PR #239 had the agent send `replaces` (the tenure it last held)
   and compared that. Its own rule 3 already reduced the compare to the lease order, so
   `replaces` decided nothing that the order does not, and it cost an upgrade order (a new agent
   got a 400 from an old server) and left agents that do not send it unprotected. It is gone,
   with the agent's kept tenure across a fence. With the order alone, **every agent version is
   held to the rule**, so no minimum agent version is needed, and a new agent works with an old
   server. The agent is unchanged: every agent, built before this change or after, reads
   ZC-E0205 at registration as a failed step and registers again on a fresh lease at its next
   step (see "Old agents" below).
4. The keepalive check (B7 slice 3) stays as it is.

## Old agents: why the refusal is ZC-E0205 (reversed 2026-11-18)

The first version of this change answered the refusal with ZC-E0510, the code of a write under
an ended tenure, and the supervisor's first ruling kept that code. Review of PR #281 asked what
an agent built before the change does with it, and the answer reversed the ruling: the
supervisor approved ZC-E0205 (option b) on 2026-11-18, with no new code.

**ZC-E0510 crashes an old agent.** An agent built before this change (0.5.x, `main` at 190f8dc)
maps every ZC-E0510 from the server to a failed compare (`succeeded = false`), and
`Agent.heartbeat` asserts that a registration's compare held: before this change no
registration was ever answered ZC-E0510, so the assert was unreachable. Measured on 2026-11-18:
a ReleaseSafe 190f8dc `zcube-agent` against the ZC-E0510 server, its registration on lease 1
held by a proxy while node1 was registered on lease 2, then released: the server answered 503
ZC-E0510, the agent printed `bug[ZC-B0001]` and exited 70. Started again on the same state
directory, it registered on lease 3 at once and ran normally (no loop). A crash and a restart,
not I1b, but an operator upgrading servers before agents would see agents exit 70.

**ZC-E0205 is a failed step for every agent.** In `agent_client.zig` (unchanged by this PR) only
ZC-E0510 is read as a failed compare; any other refusal of a registration goes to `refused`,
which raises ZC-E0504 and returns `error.BackendFailed`. `Agent.heartbeat` registers only when
it holds no lease (`agent.lease == lease_none`), so the error leaves it holding none: `reconcile`
returns from the step before any stage runs, so nothing is fenced and no container is stopped,
and the next step grants a new lease and registers on it, which the lease order accepts. The
lease granted for the refused attempt is never renewed and expires. The agent holds no tenure
on a lease it has not registered on, so there is nothing for it to fence; the keepalive's
ZC-E0205 (`LeaseNotFound`, which does fence) is a different path, taken only for the lease the
agent holds. Measured on 2026-11-18 with the same rig and the same 190f8dc agent against this
server: the server answered 503 ZC-E0205; the agent (`zcube-agent 0.5.2`) logged one failed step,
`error[ZC-E0504]` with the server's cause ("this registration of node node1 is on lease 1, older
than lease 2 the node is registered on: an earlier attempt that arrived late") and "retrying;
containers keep running meanwhile", then "node node1 registered on lease 3"; `/nodes/node1` was
on lease 3, the agent was still running, and its log held no panic and no fence. Its fix line
("look at the server's log for this request, or restart the server") is the old client's generic
text for a refusal; nothing needs doing. `agent_api_test.zig` pins the code, the status (503)
and the cause of the refusal, and the registration on a fresh lease accepted after it;
`agent_client_test.zig` pins the client's reading (ZC-E0504, `BackendFailed`, never a result).

An agent gets the refusal only when a registration of its node lands after a newer one: two
agents run under one node name (an operator's error, or a supervisor that starts a new agent
while the old one is still in a slow registration), or a registration is delayed on the wire for
as long as the agent's own step (#237 itself), or the key's lease ends between the server's read
and its write. The operator sees one failed step in the agent's log (ZC-E0504, naming the
server's ZC-E0205 and its cause) and the node registered again at the next step; no restart.

## Rejected: a minimum agent version (option A)

Option A kept #239's `replaces` and refused registrations from agents below a minimum version.
`agent_version` is self-reported and free text, so a floor on it guarantees nothing; it would
also break a mixed-version rollout (every old agent refused until upgraded) and need a new
user-visible bound. The lease order covers every agent with neither cost. The supervisor chose B
on 2026-11-18.

## The remaining gap: a key that is absent

A late PUT that finds `/nodes/<node>` absent is accepted. It overwrites no live tenure: the key
is deleted only when the lease it was on ends (expiry or revoke), and that ends the agent's
tenure too (it fences on ZC-E0205 at its next renewal, or by its own fence bound). The late
key sits on a lease nobody renews, which is older than any lease the agent grants next, so it
ends within one ttl, and the agent's next registration (on a newer lease) is accepted over it.
For that window the node looks registered with no agent renewing it, as it would between an
agent's crash and its lease's expiry; work placed there is run by the agent once it registers
again, or replaced when the late key's lease ends, the usual paths of a lost node.
`agent_api_test.zig` ("a late registration finds the key gone ...") pins it: register on L2, revoke L2, the L1 PUT is
accepted, the L3 registration is accepted over it, and revoking L1 leaves the key on L3. The
simulator's late-registration world cannot reach this case (its orphan lease ends with the
agent's), so the unit test is the only evidence.

## The barrier (test-only)

`src/server_register_barrier.zig` holds a node's registration request, for the zigcube-jepsen test
that delays a real registration while its lease is still live. It is a hook of the HTTP layer
(`server_http.Hook`) that runs before the request takes the API's write lock, so other writes
(other nodes' keepalives, a newer registration of the same node) go on while one is held, and the
held one, released, meets the key on the newer lease and comes back refused (ZC-E0205). Only
`zcube_server.zig` imports it, behind `build_options.register_barrier` (`-Dregister-barrier=true`);
every other build ignores `ZCUBE_TEST_REGISTER_BARRIER` and compiles none of it, and `dist` and
`release` set the option false. `Server.Options.hook` is null in every shipped server. The unit
test `server_register_barrier_test.zig` runs it in a real server (arm, hold, a newer registration
landing during the hold, release, `done`), so a change that breaks it fails `zig build test`;
`zig build register-barrier-build` compiles the gated server (in `check` and CI's check job).

## The tooth

`sim-c1-teeth-register_unchecked` skips the lease order (rule 1's check; the compare stays, on the
revision read) in the world of `SimNet.late_registration`: when the agent asks for a lease the
network first grants one of its own, older than the agent's; when the agent's registration is
accepted, a copy of it on that older lease is parked and delivered one second before that
lease's ttl ends. The key moves onto a lease nobody renews: I1b. The model draws nothing from the
seed and is off unless asked (`--late-registration`, or the tooth). `sim-c1-late` runs the same
world with the rule on, seeds 1..40: every check holds and every late registration is refused.
Measured on this branch (2026-11-18, `sim_c1_teeth_register_unchecked --seeds 1..40 100 --c1`):
38 of 40 seeds fail, 23 of them with I1b; the other 15 fail on liveness (11 "agents kept
fencing", 2 "a running replica was never reported", 1 J1, 1 "a replica is not running exactly
once"), symptoms of the same stale lease. With the rule on, `sim-c1-late` passes all 40.

## Old replay worlds

Not re-derived. The late registration is off by default and draws nothing, but the server's
change alters runs in which a registration meets a key on a newer lease. The fleet's seeds are
drawn fresh; `c1_regressions` and `sim-c1-regress` pass and are smoke runs of the current code.
