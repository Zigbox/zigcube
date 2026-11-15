# A node's first certificate comes from `ca issue-node`; client certificates are re-issued weekly

*Decided 2026-11-13 by the supervisor, on slice 2's review (finding A, MUST, and the client-lifetime
question). Recorded by the slice 2 fix session.*

## The node certificate

The review found that the unauthenticated credential endpoint
(`POST /v1/agent/nodes/{node}/credential`) issues `node` certificates. Anyone who can reach the
API could get one for any node name not on the `revoked` file.

- **No window on main.** Nothing accepts a `node` certificate until slice 3 puts the API behind
  TLS, so main has no window. The endpoint keeps issuing one beside the credential until then.
- **After slice 3, `--listen` has no unauthenticated path.** Every caller presents a client
  certificate. Renewing a node certificate over `--listen` must come from a caller whose
  certificate identity is `node/<the same node>`.
  - **Slice 3 acceptance item:** the credential endpoint over `--listen` issues a credential and
    a node certificate for `{node}` only to a caller whose certificate is of kind `node` and names
    `{node}`.
  - It refuses everyone else: no certificate, a client certificate of any scope, a workload or
    server certificate, or a node certificate for another node.
  - A table test covers each case.
  - The handler gets no caller identity in slice 2 (`Call` in `agent_api.zig` has no identity
    field), so this cannot be built or tested here.
- **The first certificate comes from the server host.** On the server host, the operator runs
  `zcube-server ca issue-node NAME [--out DIR] [--replace]` and copies the two files to the node.
  - The command shares `ca issue-client`'s code (`src/server_issue.zig`) and writes `NAME.key`
    (PKCS#8 PEM) and `NAME.crt` (PEM), both mode 0600.
  - It follows the same never-overwrite rule (below) and the same refusals: no CA (ZC-E0806), an
    existing file (ZC-E0806), a revoked name (ZC-E0807).
  - No new code was registered for it.
  - How the agent loads those files instead of `peer.key` is slice 3's work.
- **`--insecure-listen` (loopback only) keeps the join.** A node that reaches the server over
  loopback still joins and renews through the credential endpoint, as it does today.

## Client certificates

- **Seven days, with no ttl flag.** A client certificate lives `x509_leaf_ttl_ms_max`, the most the
  profile allows a leaf.
- **Re-issued weekly.** To re-issue, run `ca issue-client` again with `--replace`, by hand or from
  cron on the server host. A client such as Botpike's app must be re-issued weekly. docs/mtls.md
  says so.
- **Never overwrite by default.** Without `--replace`, an existing `NAME.key` or `NAME.crt` is
  refused (ZC-E0806), because the key may be in use.
- **How the files are written.** Both files are first written and synced under temporary names
  of their own.
  - Without `--replace`, each is renamed with no-overwrite (`renameat2(RENAME_NOREPLACE)` on
    Linux), and a refused second rename removes the first file again. A failure leaves neither
    file.
  - A run killed between the two renames leaves a lone `NAME.key`. A rerun refuses it and says to
    use `--replace`, which accepts it.
  - With `--replace`, each file is renamed over the old one. A failure between the two leaves a
    pair that a rerun with `--replace` fixes.
- **`peer_credential_ttl_ms_max <= x509_leaf_ttl_ms_max`** is asserted at comptime, because the
  node certificate lives as long as the credential.

Where: `src/server_issue.zig`, `src/server_config.zig`, `src/peer_files.zig`, docs/mtls.md,
docs/api.md, docs/agent.md.
