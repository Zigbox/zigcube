# B7 slice 1: the TLS 1.3 server, handoff

*Recorded by B7 slice 1, 2026-11-13. The scope decision itself is
`2026-11-13-in-house-tls-server.md`.*

## Decisions

- **The server is `src/tls_server.zig`, a pure state machine in the core.** It has no sockets and
  no clock of its own, so it is wasm-clean. It shares `tls_schedule.zig` and `tls_wire.zig` with the
  client, so neither the key schedule nor the record code exists twice. The interface is
  `init`, `receive`, `output`/`drain`, `end_of_input`, `seal_application`, `send_key_update`,
  `close_notify` and `peer`. The socket shell is slice 3's.
- **Client authentication cannot be turned off.** No config field makes the client certificate
  optional. `Config.client_kind` names the one kind taken: `workload` today, `node` and `client`
  from slice 2.
- **No new constant and no new code.**
  - The deadline, the record limits and the change_cipher_spec allowance are the client's
    constants.
  - Failures reuse ZC-E0810 to ZC-E0820, and ZC-E0809 through `x509.raise`.
  - E0814 got a server paragraph in its explanation: no certificate, so the server answered
    `certificate_required`. E0820 got one for the server's own signer. The summaries are
    unchanged, and the error pages are regenerated.
- **When the server takes a change_cipher_spec.**
  - Only while it waits for the client's flight (wait_certificate, wait_certificate_verify and
    wait_finished), and only between whole messages.
  - At most `tls_change_cipher_spec_records_max` (1) of them, with the body `01`.
  - So one may also come straight after the ClientHello, as RFC 8446 allows. The fuzzer's hello
    oracle counts it.
- **`tls_testclient.zig` is test-only, and tidy enforces it.** It is a scripted client with
  knobs for every way to be wrong. Only `*_test.zig` files and `src/tls_server_fuzz.zig` may
  import it.

## Traps found

- **A refused server is in `failed`.** `receive` asserts that the output was drained, so call
  `drain()` first; after that it returns `error.Closed`.
- **The fuzzer judges a run by what it sent, not by what the client meant.**
  - A knob drawn as its correct value (`key_bytes = 32`, a `good` enum) counts as good.
  - A damaged `ccs_byte` needs a change_cipher_spec that is actually sent.
  - Trailing bytes after the Finished are a fault only in the Finished's own record; in a record
    of their own they are a legal KeyUpdate.
  - Each of these showed up as a "false connect" before the oracle learned it.
- **Replaying a fuzz failure.** Build with `-Dtest-filter=...`, then run the newest
  `.zig-cache/o/*/test` with `ZCUBE_FUZZ_ITERATION_SEED=<seed>`. The binary takes no
  `--test-filter`.
- **`tls_server_test.zig` is imported from `src/core.zig`.** So it also runs under WASI in
  `wasm-test`. The server fuzzer and its teeth are native only (`src/tests.zig`,
  `src/mtls_teeth.zig`).

## What's next (slice 2 and after)

- **Slice 2.**
  - Add the `node` and `client` kinds in `x509.zig`.
  - Add near-miss rows for both kinds in `tls_server_test.zig` (the `client_kind` table is where
    they go).
  - Add the new kinds to the x509 fuzzer.
- **Slice 3.**
  - The socket shell: a deadline per read and write, using the client's handshake deadline.
  - ZC-E0822 for the scope.
  - mtls-interop rows with stock clients (openssl `s_client`, JDK) against this server.
- **CI does not run mtls-interop when the TLS core changes.** `.github/ci-changes.sh` triggers it
  only on `src/mtls_interop.zig` and `ops/mtls-interop/*`, so a change to `tls_client.zig`,
  `tls_wire.zig` or `tls_server.zig` does not run it. Slice 3 adds server rows to it, so it should
  widen that rule (and add a table-test row).
