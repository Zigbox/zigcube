# The B4–B7 bundle: a trial integration

*Decided 2026-11-14, by the slice (integration session), for the supervisor's review.*

This is a trial integration of B4, B5, B6 and B7 on `claude/bundle-b4-b7`. It was cut from `main` at
fb385b2 and adds no feature. Every branch went in as a merge commit, with no rebase and no squash,
in the order the supervisor gave. None was already an ancestor of `main`.

| # | Branch | Head | Merge commit |
|---|--------|------|--------------|
| 1 | `claude/b7-slice1` | 573ca43 | ceb044d |
| 2 | `claude/b7-slice4` | f6c0041 | face66c |
| 3 | `claude/b4-slice2` | 281f4e5 | a2e9525 |
| 4 | `claude/b4-slice3` | 348abae | a865785 |
| 5 | `claude/fix-server-ca-615` | 3fb60cf | df9ec8b |
| 6 | `claude/b5-slice4` | 7c44b31 | f7575fd |
| 7 | `claude/b6-slice2` | 1668b53 | 97bd1c0 |

Every merge commit's message lists its conflicts. The summary is below. Each conflict was resolved on
its merits, and both behaviours were kept. A whole file was never taken from one side.

## Conflicts and resolutions

1. **B7 slice 1, then slices 2–4.**
   - b7-slice4 forked slice 1 at 538c186, so the two share history.
   - In `tls_server.zig` and its fuzzer, slice 4's `client_kinds` set replaces `client_kind`. Slice 1's
     later review fixes are kept: the ccs oracle, the alerts and the teeth.
   - In `docs/mtls.md`, slice 4's text sits beside slice 1's ZC-E0813 sentence.
   - In the CI path rules, the TLS server now runs every job. Slice 1's own comment said it must once
     it sits behind the listener, and a table row records it.
2. **B4 slices 1–2 over B7.** Both changed the SPIFFE ID, certificate issuance and the server
   settings.
   - **The SPIFFE path.** One `Path` enum of four kinds: service and job (B4), node and client (B7).
     B7's argument order for `spiffe_write` is kept. A bad job name is `BadServiceName`.
   - **`SpiffeLeaf`.** It carries its path, and both workload paths map to `.workload`. B7's
     `path_of` is gone.
   - **`x509_near_miss`.** It has one `san_uri` helper, which both branches had written.
   - **`x509_oracle.uri_kind`.** It learned the `job` kind. This fix is not named in merge 3's
     message: see open item 4.
   - **Scope table.** B7's table in `api_test.zig` gains B4's run-certificate endpoint: the node's
     own run is allowed, and node2's run is refused.
   - **mtls-teeth.** It now has 39 teeth: 13 from main, 19 from B7 and 7 from B4.
3. **B4 slice 3.**
   - **`ops/sim-fleet/README.md`.** It keeps main's fixed `job_ledger_small` and `job_evicted`
     canary rows and adds the five R4–R7 rows.
   - **Semantic fix.** Slice 2 made a relayed spec without the loopback network a spec problem, so
     the R7 unit test now sets `spec.network = .loopback`.
4. **#615 (state directory 0700).**
   - ZC-E0806's explanation keeps B7's longer list of files.
   - It also takes the fix's two additions:
     - the CA key and `peer.key` hold 64 hex digits (said of those two only, since B7's `NAME.key`
       does not);
     - the state directory is created 0700.
   - `site/errors/E0806.html` was regenerated.
5. **B5 slice 4.**
   - **CI.** CI now has 11 verdict columns, with `demo_b7` and `demo_b5` side by side. The shared
     demo state files want both. `.github/ci-changes-test.sh` passes 76 cases.
   - **Shared code.** The agent, the runtime spec, the job API, the server and agent configs, and the
     simulator each carry both B4/B7's TLS, cluster and relay fields and B5's trust policy and
     signatures.
   - **`--strong` and `--signed`.** Both flags pass through `c1_teeth`, `sim_cluster_main`,
     `wasm_core` and `wasm_check.mjs`.
   - **Semantic fixes.**
     - B5's API test names its caller (B7's API).
     - B5's `--config` trust test listens with `insecure_listen`, since B7 made `listen` TLS.
     - Three functions over 70 lines were split: `job_api.trust_refusal`, `sim_cluster.init_jobs`,
       and the x509_identity SPIFFE test.
6. **B6 slice 2.**
   - **Placement.** A job carries B5's `signatures` and B6's `placement`. B6's implementation
     replaces main's "placement not built" refusal, and the `Present` helper, now unused, is gone.
   - **Registration.** It carries B5's trust policy and B6's labels.
   - **The WASM export.** B6 folded its world into a bit field. `zcube_sim_cluster_shaped` instead
     takes `strong`, `signed` and `tenants` as three arguments, each its own switch, matching
     B5's form.
   - **Teeth.** sim-c1 has 26 named teeth in AGENTS.md (31 runners in `build.zig`). B6's two P1
     canary rows follow `job_untrusted`.
   - **Semantic fix.** B6's service-apply test names its caller.

## Diagnostic codes

There is no collision.
- B7 registered ZC-E0822. ZC-E0810 to ZC-E0821 were already on `main`.
- B4 registered ZC-E0706.
- B5 uses Zigbox's ZBX-E0905 and ZBX-E0906 and adds no ZC- code.
- B6 adds none.
- #615 only rewords ZC-E0806.

No bound, limit or default was changed by the integration itself.

## The Zigbox pin

The brief asked for Zigbox v0.5.1. That tag does not exist: Zigbox has only v0.5.0. So the pin stays
at aa4d64c, which is the pin every merged branch already used.

## For the supervisor

1. **The run-certificate endpoint and the admin scope.** B7's scope table lets the `admin` client
   scope call B4's run-certificate endpoint. B4's node credential endpoint is node-only. Should a run
   certificate be node-only too? The bundle keeps what the two branches do together and changes
   nothing.
2. **Two PEM modules.** B4's `pem_anchor` may duplicate B7's PEM module. This is a candidate for a
   later cleanup, not changed here.
3. **Relayed jobs under `--signed --strong`.** In this world, relayed jobs pin `sim_trust.image`, as
   every signed job does. The R4 image compare then sees one image. That is still a valid check,
   but it is a narrower world than B4 measured its canaries in.
4. **Merge 3 history.**
   - The commit message of a2e9525 does not name the `x509_oracle` fix it carries.
   - The commit has a duplicated `Signed-off-by` line.
   - Commits a2e9525 to df9ec8b fail `zig build tidy`: the x509_identity test was too long. f7575fd
     fixes it.
   - History is merge-only, so this is left as it is.
5. **sim-c1 now always runs the strong world.** This holds since B4 slice 3. B5 added the signed
   comparison and B6 added `-Dtenants`. B6's `plan` turns `--tenants` on for `auto` operations, so a
   pre-B6 `auto` replay line no longer replays its old world.
6. **Demos still pending.** demo-b4 lives on `claude/b4-slice4` and demo-b6 on `claude/b6-slice3`,
   and this bundle has neither. demo-b3 and demo-b5 need KVM and were not run in the cloud.

Where: the merge commits' messages, `docs/releases/b4-b7.md`.
