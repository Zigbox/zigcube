# A registration on an older lease is refused (#237)

Status: decided 2026-11-18 (takes PR #239 forward; the brief "correctness and evidence fixes for
0.6.0", item 1). PR #239's decision file, never merged, is folded into this one.

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
   than the registration's, the registration is refused (ZC-E0510, no new code) and moves
   nothing. Otherwise the server writes in one transaction compared on the revision it read
   (0: absent), so a registration that races another one between the read and the write is
   refused the same way.
2. **Why the order is enough.** The #237 PUT is an earlier attempt, so its lease is older than
   the one the agent registered on next: lease ids only grow (SQLite `AUTOINCREMENT`, a Postgres
   identity column, the memory store's counter; a conformance test), and an agent grants its
   lease before it sends. Every legitimate retry (a lost reply, a crash before the agent
   recorded the tenure, a server restart, a wiped state directory) carries a lease at least as
   new as the key's and is accepted at once.
3. **Nothing from the agent.** PR #239 had the agent send `replaces` (the tenure it last held)
   and compared that. Its own rule 3 already reduced the compare to the lease order, so
   `replaces` decided nothing that the order does not, and it cost an upgrade order (a new agent
   got a 400 from an old server) and left agents that do not send it unprotected. It is gone,
   with the agent's kept tenure across a fence. With the order alone, **every agent version is
   held to the rule**, so no minimum agent version is needed and there is no upgrade order: a
   new server protects old agents, and a new agent works with an old server. (The agent's client
   still reads ZC-E0510 on a registration as a failed step rather than a failed compare, so it
   does not assert; an old agent that meets the refusal fails its step the same way and
   registers again on its next one.)
4. The keepalive check (B7 slice 3) stays as it is.

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

## The barrier (test-only)

`src/server_register_barrier.zig` holds a node's registration transaction just before it runs,
for the zigcube-jepsen test that delays a real registration while its lease is still live. It is
compiled only with `-Dregister-barrier=true` and armed only by `ZCUBE_TEST_REGISTER_BARRIER=DIR`;
`zig build`, `dist` and `release` leave it out. The lease order is checked before the barrier and
the compare after it, so a registration released after a newer one took the key comes back
refused in both orders. It is shell code (files, a sleep) and wraps the store's `txn` only.

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
