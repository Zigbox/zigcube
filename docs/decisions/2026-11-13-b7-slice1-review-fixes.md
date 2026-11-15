# B7 slice 1: fixes after the review

*Recorded by the B7 slice 1 fix session, 2026-11-13. It adds to
`2026-11-13-b7-slice1-handoff.md` and supersedes it where they differ (the alert rules below).*

## Decisions

- **The fuzzer judges change_cipher_spec faults by the records the server read.** The damage
  step can drop the bad record or move it behind the Finished, after which a connect is right.
  A fault confined to those records sets `knobs_ccs`, and the server may connect when
  `knobs_good or knobs_ccs` and `flight_whole` holds. This is the oracle of
  `claude/b7-slice2` (cd197db), taken word for word so slice 2 merges cleanly on top. Iteration
  seeds 2070481195666110524 and 8609624064817084225 are regressions.
- **A fuzzer tooth first runs its seed range with the fault off** and fails if any seed connects
  falsely there, so a tooth cannot pass on an oracle that is wrong without the fault.
- **The alert is plain whenever the client holds no keys.**
  - A failing signer: the server drops its ServerHello with the flight, so it wipes its write
    keys before the alert. E0820's summary now covers both sides ("a client's or this server's
    certificate").
  - A refused ClientHello: the key-change boundary check (bytes behind the hello in its record)
    now runs before the hello is taken, so no keys exist when the alert is queued.
- **`Config.client_kind` has no default.** Each listener names its kind.
- **New refusals, all with existing codes:** `key_share` without `supported_groups`
  (`missing_extension`, ZC-E0813); a Certificate with a request context and no certificates
  (`illegal_parameter`, ZC-E0813); a protected handshake record with no content (ZC-E0815).
- **`pre_shared_key` is ignored, not refused**, when it comes last; docs/mtls.md says so.
- **The fuzzer's draw of faults is unchanged.** Adding the new hello knobs to `random_faults`
  would change what every iteration seed draws, the two regression seeds included; they are
  covered by near-miss rows and teeth instead.
- **CI:** `src/tls_server*.zig` and `src/tls_testclient.zig` run the mtls-interop job. Slice 3,
  which puts the server behind `zcube-server`, must widen that rule.

## Open question for the supervisor

The API listener of slice 3 takes both `node` (the agent) and `client` (`zcube`) certificates,
and `Config.client_kind` holds one kind. Either the listener takes a set of kinds, or it verifies
the chain for each kind in turn. Neither is built; slice 3 needs the answer.

## Traps

- Test faults are global. A test that turns one on must `defer` turning it off, or later tests
  in the same binary run with it on.
- `rig.server.read.updates` and `write.updates` can be set directly to test the KeyUpdate limit
  without 65,536 updates.
- The filtered fuzz binary is `.zig-cache/o/*/test` after
  `zig build test -Dtest-filter="fuzz: a damaged client flight"`; run it with
  `ZCUBE_FUZZ_SEED` and `ZCUBE_FUZZ_ITERATIONS` (the build's run step is cached and does not
  see them).
