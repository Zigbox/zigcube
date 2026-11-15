# B7 slice 3 handoff: the API over TLS

Date: 2026-11-13. Branch `claude/b7-slice3`, from `claude/b7-slice2`.

## What was built

- `zcube-server --listen` serves TLS 1.3 (`server_tls.zig`, around `tls_server.zig`);
  `--insecure-listen` serves plain HTTP, loopback only (anything else is ZC-E0106). With neither,
  TLS listens on `127.0.0.1:7070`. `--tls-name` (default `zcube-server`) is the DNS name of the
  server's certificate.
- The caller (`api_scope.Caller`: `local`, `node`, `client` with a scope) is named from the
  verified certificate and travels in `api.Request.caller` (a required field: there is no default,
  so a forgotten one fails to compile instead of allowing everything). `Api.route` asks
  `api_scope.refusal` first; a refusal is 403 ZC-E0822 (registered in 197949c; goldens, the
  errors site and the console mock's code list are generated).
- `zcube`: `--ca --cert --key --tls-name`, or `ZCUBE_CA ZCUBE_CERT ZCUBE_KEY ZCUBE_TLS_NAME`.
- `zcube-server ca issue-node NAME` (a node bootstrap certificate) beside `ca issue-client`.
- `zcube-agent`: the same flags or ZON keys. It presents its own `node.crt` and `peer.key` once
  it has joined (and the new one after each renewal), else `--cert`/`--key`.
- `tls_server.Config.client_kinds` is a required set of kinds (the API takes `{node, client}`),
  replacing `client_kind` and the `client_kind_also` this slice first added; ZC-E0819 names
  every kind taken (`2026-11-13-api-listener-cert-kinds.md`). When slice 1's fix (573ca43,
  `client_kind` required) merges, `client_kinds` replaces it.
- `api_tls_client.zig` is the client side shared by both (files, the pin, one exchange).
- Tests: `api_test.zig` "scopes: every endpoint ..." (every endpoint x node1, jobs, admin, plus
  node2's paths), `api_tls_test.zig` (real server, real certificates), config and flag tests.
- The harnesses (agent-smoke, local-smoke via `zcube local`, demo-c0/c1 via `demo_host`,
  swarm-smoke, store-failover) start the server with `--insecure-listen`.

- Merged claude/b7-slice2's fix (f58f605): its `ca issue-node` and `--replace`
  (`server_issue.zig`) replace this slice's `server_issue_client.zig`; the usage keeps both
  slices' flags. The credential endpoint over `--listen` is the node's own certificate's
  only, never a client's, admin included (`api_scope` `.node_only`, fixed after review on
  2026-11-14; the endpoint x caller table refuses node2, a jobs client and an admin,
  `2026-11-13-node-cert-bootstrap.md`); over `--insecure-listen` the old join path stays.

## Open questions for the supervisor

1. **Agent bootstrap** (decided by the supervisor, `2026-11-13-b7-supervisor-calls.md`):
   `zcube-server ca issue-node NAME` writes a node certificate; the agent presents it until it
   holds `node.crt`, and refuses an admin's or another node's certificate as `--cert`.
2. **The CLI has no ZON config file**; environment variables stand in for "a ZON config with
   the same keys" on the `zcube` side. The agent has the ZON keys.
3. **The default listener is now TLS.** `zcube-server` with no listen flag serves TLS on
   127.0.0.1:7070, so `zcube` with no flags (plain HTTP to 127.0.0.1:7070) no longer reaches it.
   This follows from "`--listen` serves TLS" but changes what a bare start does.
4. **The console** works on `--insecure-listen` only: a browser presenting a client certificate
   is not set up.

## Traps

- `pem.decode` wants the exact text with the trailing newline after END.
- `x509_identity.dns_problem` returns `bool`, not a reason.
- `api_tls_client.Credentials.present` refuses (returns false) a certificate the pinned CA did
  not issue, so an agent whose state directory is from another CA falls back to `--cert`.

- The CA certificate in the state directory is `ca-<hash>.crt` when the store is a file (one CA
  per store, `server_ca.key_name_for`), not `ca.crt`; `api_tls_test.zig` asks the server for it.
- A GET with a body is 400 before the scope check: send none.
- `src/tests.zig`'s first `test {}` block is at the 70-line limit; new test files go in the second.

## What ran

`zig build test`, `tidy`, `errors-site-check`, `agent-smoke`, `local-smoke`,
`demo-c0 -Dbackend=sqlite`, `demo-c1 -Dbackend=sqlite`, `zig build check`. Not run: the Postgres
demos and suite (the store did not change), `mtls-interop`, `swarm-smoke`, `demo-b3`, and every
harness over TLS (they use `--insecure-listen`).

## Next

Slice 4 of docs/briefs/b7.md.
