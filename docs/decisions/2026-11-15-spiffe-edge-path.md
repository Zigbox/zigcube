# The edge's SPIFFE ID is spiffe://<cluster>/edge/<node>

*Proposed 2026-11-15 by the supervisor (C5 brief review, ruling R2). **Status: Accepted (owner,
2026-11-15).** The owner said yes on 2026-11-15; slice work may implement it.*

`2026-11-04-spiffe-service-path.md` fixed workloads at `spiffe://<cluster>/service/<name>` and says
another path kind needs its own decision. C5's edge is a mesh caller that is not a service, so it
needs one.

**Proposal.** A new kind in `x509_identity`:

    spiffe://<cluster>/edge/<node>

- `<node>` is the node name, with the node-name charset.
- Issued by the server's CA like `/service/<name>` (1 h, renewed at half-life), and only to a
  caller that proves `/node/<node>` while the operator has turned the edge role on
  (`/edge-roles/<node>`, written by `zcube node edge <node> on`). The agent never asserts the
  role. A node without it is refused with ZC-E0716.
- Used only as a mesh source. A destination accepts it only through a grant derived from `public`;
  a user grant naming `edge` is refused (ZC-E0714). It also authorizes the key handover
  (`POST /v1/edge/keys`) and the challenge lookup.
- The near-miss table, goldens and fuzzer gain the kind (`/edge/` vs `/edges/`, `/Edge/`, an empty
  node, a service name in the node slot).

**Alternatives the owner may prefer.**

- Reuse `/node/<node>` and decide edge rights from the role alone. Fewer kinds, but every node
  certificate would become a possible mesh source, and a destination could not tell an edge call
  from a node's own.
- `/service/edge-<node>`. Rejected: it would let a user service named `edge-x` collide with it.

Where: `docs/briefs/c5.md` ("Ask the owner first", A13; "The edge role"; slice 4a).
