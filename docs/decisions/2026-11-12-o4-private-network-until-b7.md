# O4: the API stays on a private network until B7

Date: 2026-11-12. Decided by: the owner.

## Question

Botpike's brief (`docs/briefs/botpike-first-customer.md`, owner question O4) asks how the API is
protected before the in-house TLS server exists: a private network only, or a TLS front that
checks a bearer key scoped to jobs.

## Decision

A private network only, until B7. `zcube-server` listens only on a private network that it
shares with Botpike's app. Nothing on that network carries a client identity, so the network
boundary is the only control on the API's writes; this is the known limit in `docs/api.md` and
`docs/agent.md`, and it stays documented there until B7.

No interim TLS front and no bearer key are built. B7 is mTLS on the server side, with a client
certificate from the cluster CA and a scope that allows jobs and nothing else, as the brief says.

## Consequences

- B7's brief plans only the mTLS server work; there is no interim to remove.
- Botpike's deployment must put its app and `zcube-server` on one private network, and must not
  expose the server's listener elsewhere until B7 ships.
