# B7 slice 2: node and client certificates, handoff

*Recorded by B7 slice 2, 2026-11-13. The decisions it made have files of their own:
`2026-11-13-identity-extension-v2-scope.md`, `2026-11-13-cluster-name-from-ca-key.md`,
`2026-11-13-revoked-names-shared.md` and `2026-11-13-node-certificate-beside-credential.md`.*

## What landed

- **Two kinds in `x509.zig`.** `node` (`spiffe://<cluster>/node/<name>`) and `client`
  (`spiffe://<cluster>/client/<name>`) are both clientAuth only. A `client` certificate carries
  identity extension v2 (`30 06 02 01 02 0A 01 0s`, jobs = 1, admin = 2). A `node` certificate
  carries no identity extension. Version 1 extensions still parse for the kinds that had them.
- **Node certificates at join.**
  - `POST /v1/agent/nodes/{node}/credential` answers with `node_certificate` (hex DER) beside the
    credential: the same key and the same life.
  - The agent checks it and stores it as `node.crt` (PEM, 0600). Renewal replaces it, on disk too.
  - `src/pem.zig` holds the strict PEM and PKCS#8 code.
- **`zcube-server ca issue-client NAME --scope jobs|admin [--out DIR]`.** It is given the server's
  `--store`/`--state-dir`/`--config`.
  - It opens the existing CA (never makes one) and refuses a name on the `revoked` file
    (ZC-E0807).
  - It writes `NAME.key` (PKCS#8 PEM) and `NAME.crt` (PEM), both 0600. It refuses to overwrite
    either (ZC-E0806).
  - The certificate lives `x509_leaf_ttl_ms_max` (7 days).
  - `src/server_issue_client.zig`; the parsing is in `server_config.zig` (`Command.ca_issue_client`).
- **Tests.**
  - Near-miss rows for both kinds, in `x509_near_miss.zig` and the `client_kind` table of
    `tls_server_test.zig`.
  - The x509 fuzzer and its oracle draw all five kinds.
  - The server fuzzer accepts a flight whose only fault was in change_cipher_spec records that the
    damage cut or mended (`knobs_ccs`): a false "false connect" seen once in a long run.
- **No new code and no new constant.** The summaries of E0817 and E0819 now name the new kinds,
  and the pages and goldens are regenerated. ZC-E0822 (scope) is slice 3's.

## Traps found

- **Text mode prints only the last `diag.cause`.** Put a diagnostic's whole cause in one line.
- **`server_ca.open` with a SQLite store names the key by the absolute database path**
  (`key_name_for`). `issue-client` must resolve the path the same way, or it finds "no CA key"
  for a store the server uses.
- **A memory store has no CA to issue from.** `issue-client` refuses it with ZC-E0106.
- **Test identities.** `Peer.hold_for_test` makes a credential and node certificate that match.
  Tests that used to set `credential` and `ca_public` by hand
  (`peer_server.zig`, `zigbox_fetch_owner_test.zig`) now call it, because `store` writes
  `node.crt` too.

## Open (asked of the supervisor)

- **Where the cluster name comes from.** Today it is derived from the CA key
  (`zc-` + 16 hex digits of SHA-256 of the public key). The alternative is a `--cluster` flag,
  which would be a new user-visible setting.
- **The client certificate's lifetime.** It is 7 days today, the profile's maximum. A shorter
  default, or a flag, would be a user-visible default.
- **The E0807 summary still says "a node".** The `revoked` file now also refuses clients.

## What's next (slice 3)

- The socket shell around `tls_server.zig`, with a deadline per read and write.
- The scope check, ZC-E0822: a `jobs` client refused on admin routes.
- mtls-interop rows: stock clients (openssl `s_client`, the JDK) presenting a `client` and a
  `node` certificate made by `ca issue-client` and by join.
- **Version skew.** An agent of this slice requires `node_certificate`. Upgrade the server before
  the agents.
