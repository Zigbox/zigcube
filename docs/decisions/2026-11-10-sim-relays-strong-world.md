# Simulated jobs name a relay only in the strong world

Date: 2026-11-10. Decided by: the supervisor (B3 slice 3).

The cluster simulation's jobs may name a relay (`sim-relay`) only with `--strong`, and so under
`auto` operations and the teeth that imply it (`job_wipe`, `job_unclaimed`, `job_evicted`,
`relay_leak`): every seventh job (`job_next % 7 == 3`), no random draw. Runs without `--strong` are
their old worlds bit for bit; strong and `auto` worlds now start relayed jobs (placement and
draws are unchanged, only the runtime's listener model and the report's relays line are new).
`SimRuntime` opens the listener at start and closes it on every ending; R1 to R3 judge it
(docs/core.md, "Relays"). `sim-c1-regressions` and `sim-c1-regress` must still pass; a replay
whose outcome changes is reported, never adjusted.
