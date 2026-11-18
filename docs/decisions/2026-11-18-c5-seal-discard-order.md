# `--discard-sealed`: what it deletes, in what order, and what slice 2 tests of it

*Decided 2026-11-18, by the slice (C5 slice 2).*

- **Deletes, then the key.** Every record under `/edge-certs/`, `/acme-account/` and
  `/acme-orders/` is deleted first (transactions of at most 16 deletes, each compared on its
  `mod_revision`), and only then is a new key made and written. A crash between the two leaves
  the old key file (or none) and no sealed records: the next start without the flag opens or
  makes a key and starts. The reverse order could leave a new key beside old records, which is
  ZC-E0824 again.
- **Through the verified store, straight.** The deletes go through the server's verified store
  (its rollback guard sees them), not through `writers.zig`'s roles: the server writes these
  prefixes as the ACME shell, and slice 3b registers that writer.
- **ZC-W0808 prints every cause** (`--verbose` rendering): the count, the new key's id and the
  limits all matter once, and the default rendering shows only the last cause.
- **"Then a new order on the next start."** Orders are slice 3b's. Slice 2's tests check what
  makes that order possible: the records and orders are gone, the next start without the flag
  opens with the new key, and a record sealed with it opens at the start after. 3b's tests add the
  order itself.
- **The flag stays a start flag.** A start with it discards every time; W0808 says to leave it out
  afterwards. It is refused with `ca issue-*`.

Where: `docs/sealing.md`, `src/server_seal.zig` (`discard`), `src/server_config.zig`.
