# A registration names the tenure it replaces (#237)

Status: decided 2026-11-13 (review of PR #239).

## Problem

An agent grants a lease and registers on it. If that attempt is delayed on the wire, the agent
tries again on a newer lease and holds tenure. The delayed attempt then arrives: the server moved
`/nodes/<node>` onto the older lease, which nobody renews. The key vanishes when that lease
expires, the node is marked lost while its agent runs its replicas, and they are replaced
elsewhere (I1b).

## Decision

1. `PUT /v1/agent/nodes/{node}` takes `replaces` (the tenure the agent last held, 0 for none). The
   server writes in one transaction compared against the key's `mod_revision` (0 when absent).
   Another revision is ZC-E0510, nothing written.
2. The lease keepalive refuses (ZC-E0205) a lease the node's key is not on.
3. **Only a registration older than the key is refused.** The compare is on the lease, not only on
   the tenure: a registration naming a moved tenure is refused (ZC-E0510) only when the key is
   on a NEWER lease than the registration's. The #237 PUT is an earlier attempt, so it carries a
   lease older than the agent's; lease ids only grow (SQLite `AUTOINCREMENT`, a Postgres
   identity column, the memory store's counter, and a conformance test), and an agent grants
   its lease before it sends. Every legitimate retry (a lost reply, a crash before the agent
   recorded the tenure, a lost ack, a server restart, a wiped state directory naming 0) carries a
   newer lease than the key's and is accepted at once. This replaces the first version of this
   decision (accept only a key on the same lease, with the agent keeping the lease it granted),
   which refused those retries until the old lease expired: over seeds 1..130 (100 operations,
   `--c1`) it raised nodes marked lost from 325 to 462 and replicas replaced from 678 to 1,035,
   and the agent's kept lease (`error.Unreachable` is never seen: the remote store reports
   ZC-E0503) never ran. That machinery is gone. A same-lease duplicate of an accepted attempt
   still rewrites the key (it moves its `mod_revision`, as on main), so the tenure the agent
   recorded is stale for its next compare; it is accepted by the rule, and a keepalive does not
   compare revisions. Not closed here: a late PUT that finds the key absent is accepted.
4. **The agent keeps its tenure past a fence.** `fenced()` rewrites `lease.json` with no lease
   and the last tenure, instead of removing it, and a restart reads the tenure back. This is not
   needed for acceptance: a restart's registration carries a newer lease than the key's and is
   accepted by rule 3 whatever tenure it names (a wiped state directory names 0 and is accepted
   the same way). Keeping the tenure only lets the restart's compare name the key's revision.
   (Within one process the tenure is kept in memory whatever the file says; across a restart only
   the file carries it.) It is not load-bearing.

## Mixed versions

Upgrade the server first. A new agent against an old server gets a 400 on every registration (the
old server refuses the unknown member `replaces`). An old agent against a new server is not
compared; the keepalive rule limits the damage to the time until its next renewal, and #237 is
closed only when every agent is upgraded. We do not make the server require `replaces` of agents
that report a version, because a server has no way yet to tell which registrations come from an
agent that is able to send it; revisit when agent versions are compared.

## The tooth

`sim-c1-teeth-register_unchecked` skips (1) and (2) and models the race as it happens
(`SimNet.late_registration`): when the agent asks for a lease the network first grants one of its
own, older than the agent's; when the agent's registration is accepted, a copy of it on that older
lease is parked and delivered one second before that lease's ttl ends, the latest it can, so the
agent has least time to be refused. The key moves onto a lease nobody renews, which expires with
the agent quiet or cut off: I1b. The model draws nothing from the seed and is off unless asked (`--late-registration`, or the
tooth). Measured: 22 of seeds 1..40 fail I1b (100 operations, `--c1`); the others end in a
liveness failure (`agents kept fencing`, `a running replica was never reported`), which the
canary does not accept. The canary expects I1b over 40 seeds (a miss at p = 0.5 is 9e-13). The
tooth skips both the compare and the keepalive check. Measured at 9c1358d over the same seeds of
the late-registration world, patching out each half in turn: with the compare skipped (keepalive
check kept), 40 of 40 seeds fail (19 with I1b); with the keepalive check skipped (compare kept),
0 of 40 fail. So the compare alone fixes #237, and no simulation exercises the keepalive check:
its only coverage is the unit test in `agent_api_test.zig`, and its purpose is to limit an old
agent that sends no `replaces`. Weakening it leaves the tooth and `sim-c1-late` green.
`sim-c1-late` runs the same world with the fix on: seeds 1..40 pass, every stale registration
is refused, and a seed in which no late registration was delivered fails.

## Old replay worlds

Not kept. With the late registration off, `park()` draws in the old order (after a free slot is
found), but the agent and server changes (`replaces` in the request, the kept tenure file, the
keepalive check) still alter runs: against base f7736a7, seeds 1..30 (100 operations, `--c1`)
differ in the revision, fault, fence or lost-node lines for 10, and in an agent failure count for
12. So `c1_regressions` and the `sim-c1-regress` seeds, which pass, are smoke runs of the
current code, not proof that each still reaches the bug it was added for; they were not
re-derived (that needs each seed to fail with its fix reverted, per regression), and the fleet's
seeds are drawn fresh in any case. Measured, base vs head, seeds 1..130 (100 operations,
`--c1`): nodes marked lost 325 vs 329, replicas replaced after the grace 678 vs 694.

## Not changed

The summaries of ZC-E0510 and ZC-E0205 stay as they are (the CLI golden files and the site
index quote them); their explanations say what the new refusals mean.
