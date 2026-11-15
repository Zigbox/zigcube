# B7 slice 7: a node certificate may read `/node-store/`, nothing more of `/v1/list`

*Decided 2026-11-14 by the supervisor, under the owner's standing rule (make sane assumptions
and record them).*

## The problem

The swarm fetch (`zcube-agent fetch`, `src/fetch_cli.zig`) finds its peers by reading the
server's `GET /v1/list?prefix=/node-store/`, and for O5's wait (docs/briefs/c2.md) it also reads
`/replicas/` and `/assigned/` to learn which nodes fetch the same tree. Slice 7 makes it read
over TLS with the node's own certificate, but under `--listen` a node certificate could call
only `/v1/agent/nodes/<its name>/...`: every `/v1/list` was admin's, so the read was refused
with 403 ZC-E0822 and the fetch found no peers (swarm-smoke: every chunk from the registry).

## The options

- **A.** A node may list `/node-store/`, `/replicas/` and `/assigned/`.
- **B.** A node may list `/node-store/` only.
- **C.** A server-computed endpoint under the node's own path (`/v1/agent/nodes/<self>/...`)
  that answers the fetch's question (peers, and which nodes fetch a tree) without exposing the
  records.

## The decision: B

A node certificate may `GET /v1/list` with `prefix` exactly `/node-store/` (after
percent-decoding) and no other parameter but `limit`, `at` and `continue`, each at most once.
No other method, prefix or parameter (`reverse` included), and no watch. Everything else stays
admin's (`api_scope.zig`, `node_store_query`), with near-miss rows in its tests and a tooth in
`mtls-teeth` (the prefix check switched off lets a node read `/services/`).

Over TLS the fetch reads no fetchers (`/replicas/`, `/assigned/`), so it does not wait as O5
says: it reads `/node-store/` once and goes on, as before O5. Over plain HTTP nothing changes.

**Why A was refused.** A node must not read other services' specs: `/replicas/` (and
`/services/`) hold their env. A compromised node would read every service's secrets.

**Follow-up.** If the O5 wait is wanted over TLS, the way is C, a server-computed endpoint
under the node's own path, not A.
