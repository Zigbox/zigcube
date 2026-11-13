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
3. **A retry of a lost reply is accepted.** A registration whose lease is the lease the key is
   already on is the same registration sent again, so it is accepted (the key is rewritten on
   that lease; a registration on another lease naming a moved tenure is still ZC-E0510). The
   agent keeps the lease it granted when its registration got no answer (`error.Unreachable`:
   the request may have landed) and retries on that lease. Any answer, a refusal included,
   drops the lease, so a lease the server has ended (ZC-E0205) is not retried. Without this a
   lost reply costs up to one ttl: the key sits on a lease no agent holds, and every retry on a
   new lease is refused until that lease expires. The pending lease is in memory only: a
   restart grants a new one, and is refused only until the old lease expires.
4. **The agent keeps its tenure past a fence.** `fenced()` rewrites `lease.json` with no lease
   and the last tenure, instead of removing it, and a restart reads the tenure back. A restart
   after a fence therefore registers with the tenure the key still has, and is not refused until
   the old lease expires. A state directory that was wiped names 0 and is refused for up to one
   ttl while the key is still on the old lease; that is bounded and safe, and the node's own
   replicas were lost with the directory.

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
the agent quiet or cut off: I1b. The model draws nothing from the seed and is off unless asked
(`--late-registration`, or the tooth), so old replay lines keep their worlds. Measured: 22 of
seeds 1..40 fail I1b (100 operations, `--c1`); the others end in a liveness failure (`agents kept
fencing`, `a running replica was never reported`), which the canary does not accept. The canary
expects I1b over 40 seeds (a miss at p = 0.5 is 9e-13). `sim-c1-late` runs the same world with
the fix on: seeds 1..40 pass, every stale registration is refused.

## Not changed

The summaries of ZC-E0510 and ZC-E0205 stay as they are (the CLI golden files and the site
index quote them); their explanations say what the new refusals mean.
