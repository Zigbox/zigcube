# B7 slice 7: O5 stays on over TLS, through a node-scoped fetchers read

*Decided 2026-11-14 by the supervisor on the review of slice 7 (MUST 1); written by the fix
session. It takes up the follow-up of
[2026-11-14-b7-slice7-node-store-read.md](2026-11-14-b7-slice7-node-store-read.md), whose option
B left the fetch without O5's wait over TLS; that file is not edited.*

## The decision: C(a)

O5's election (docs/briefs/c2.md, decisions/2026-11-05-o5-registry-first.md) stays on over TLS.
The fetch no longer lists `/replicas/` and `/assigned/` itself, over TLS or plain HTTP: it asks
the server

    GET /v1/agent/nodes/<self>/fetchers/<digest>

which the server computes (`agent_api.zig`, `fetchers`): the names of the nodes assigned a
replica whose image is `digest`, each once, in key order, as `{"revision", "nodes", "chain"}`.
It sits under the node's own path, so a node certificate may call it for itself only (mtls.md,
"Scopes"); another node's path is 403 ZC-E0822.

**What a node learns.** Node names and the digest it asked about, nothing else: no service, no
replica id, no spec, no env. A node already sees node names in `/node-store/`. Any digest may be
asked; a node learns which nodes run an image whose digest it already knows.

`begin()` in `fetch_cli.zig` passes the real fetchers over TLS (the slice's first version passed
none). The `/node-store/` read of the earlier decision stays as it is.

**Tests.** `api_scope` has rows for the endpoint (own node allowed, another node refused) and
near-miss rows (`/env/`); `mtls-teeth` has a tooth for each scope check switched off;
`api_tls_test` checks, through the server, that a node lists `/node-store/` and its own
fetchers and gets 403 ZC-E0822 for `/services/` (plain, percent-encoded, as a second prefix),
`/replicas/`, `reverse` and node2's fetchers; `fetch_cli` checks a refused read, a missing CA
and a missing key over TLS, and that O5 waits on the endpoint's answer.

## The fetch waits for its identity (review SHOULD b)

The agent's pass runs the peer step before it has joined (the join needs a lease and its
tenure), so a fetch child could start before `peer.cred` and `ca.pub` exist; it then asked no
peer, and swarm-smoke flaked. When the fetch has peers or a server to ask, it now re-reads the
identity every `fetch_peer_poll_ms` (1 s) for up to `fetch_peer_wait_ms` (30 s), the existing O5
bounds; no new bound. If it is still missing, the fetch says **ZC-E0806** (existing code, "no
peer identity", with the node and the two file names) and goes on from the registry.
Reusing E0806 rather than registering a warning was put to the supervisor; until they answer,
E0806 stands. swarm-smoke's wait for the `/node-store/` summaries was removed (MUST 2): it
passed 10 of 10 without it.

## Corrections

- **The cost of a server read over TLS (review SHOULD e).** Each read is a new TCP connection
  and a full TLS 1.3 handshake: `api_tls_client.exchange` serves one request per connection.
  `close` flushes and sends close_notify and does not wait for the peer's
  (decisions/2026-11-05-tls-conn.md); it is bounded at 1,000 ms. An O5 wait of 30 s at one read a
  second is up to 30 handshakes per fetch. The slice's report put the cost in waiting for the
  peer's close_notify; that was wrong.
- **`fetch_argv_max` is 26, not 28** (`zigbox_supervisor.zig`): 14 fixed words, `--server` and
  `--digest` with their values, and 8 for `--ca`, `--tls-name`, `--cert` and `--key`, tied by a
  comptime assert; exact 26-word tests in both runtimes.
- TLS paths are made absolute at the agent's config (`agent_config.zig`), as the state directory
  is, since the fetch child runs in another directory.

## A product gap, not fixed here (review SHOULD c)

`FakeRuntime.start` answers `.started` before the fetch ends, so `/observed/` reports a replica
`running` while its image is still being fetched; docs/agent.md says it is `starting` until then.
swarm-smoke's comment no longer claims otherwise. To be filed as an issue after the b3 tag.
