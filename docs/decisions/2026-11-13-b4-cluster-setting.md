# B4: the server's `.cluster` setting, and ZC-E0706 answers 409

*Decided 2026-11-13, by the supervisor (approved on the slice's request, B4 slice 2).*

## `.cluster`

`zcube-server`'s ZON configuration gains `.cluster`: the SPIFFE trust domain of a relayed run's
certificate, `spiffe://<cluster>/job/<name>`. It is a DNS name of at most 63 bytes
(`x509_cluster_bytes_max`); anything else is ZC-E0106.

- There is no default. The certificate endpoint, `POST /v1/agent/nodes/<node>/runs/<job>/certificate`,
  answers **404** until `.cluster` is set, so a server that was never told its trust domain
  issues nothing rather than certificates in a made-up one.
- A configuration that names a TLS relay (any relay without `plain`) and no `.cluster` is refused
  at load with ZC-E0106 ("relay NAME needs .cluster to be set").
- `zcube-server --help` and the module comment of `src/server_config.zig` say this.

## ZC-E0706 is 409

The server refusing a run's certificate (not this node's claim, a stale epoch, a run that has
ended) answers **409**, not the 503 its `environment` blame would give by default. The run's
claim is lost; a retry cannot change that. The agent writes `relay.refused` and the refusal line
to `relay.log` and does not ask again; the relay stays closed.

## Upgrade notes (B3 to B4)

What an operator must do:

1. Set `.cluster` in the server's ZON file to the cluster's trust domain, e.g.
   `.cluster = "prod.example"`. Every upstream that pins the cluster CA must expect
   `spiffe://prod.example/job/<name>`.
2. Give each relay `.server_name` (the DNS name the upstream's certificate carries) and
   `.server_ca` (a PEM file with the Ed25519 CA that signs it). A relay with neither is refused.
3. Jobs submitted before B4 carry no upstream name and CA: their relay will not open
   (ZC-E0702, "submit it again"). Resubmit them.
4. Release builds refuse `.plain = true`; it exists for Debug test rigs only.

Order: **the server first, then the agents.** A B4 agent against a B3 server gets 404 from the
certificate endpoint, retries every `peer_join_retry_ms` and never dials, so its relayed jobs
reach no upstream (ZC-E0705) until the server is upgraded. A B3 agent dials plain TCP and an
upstream that now wants TLS refuses it. Jobs without a relay are unaffected either way.

Where: `src/server_config.zig`, `docs/api.md` (the endpoint), `docs/agent.md` (relay files),
`docs/mtls.md` (issuance is unauthenticated until B7).
