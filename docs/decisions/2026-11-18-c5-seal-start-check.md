# The start-up check of sealed records

*Decided 2026-11-18, by the slice (C5 slice 2).*

- **Where.** `Server.start` opens the sealing key after the store's first check and **before** the
  CA: a start refused with ZC-E0824 makes nothing (no CA on a new state directory), and the CA
  file, which deployments wait for, is written no earlier than before (the Jepsen recipe's race,
  `2026-11-18-recipe-waits-for-listener.md`).
- **What it reads.** Every record under `/edge-certs/` and `/acme-account/`, through the raw store
  (not the verified store: reading needs no write guard), page by page at one revision. A value
  with no envelope is skipped. The first record that does not open stops the scan, and the
  refusal names it (with `--verbose`); the last cause, the one shown by default, names the key id
  the records expect and the key file, missing or holding another id.
- **Bound.** At most `seal_scan_pages_max` (4096) pages of 500 per prefix, about two million
  records. Past it the start is refused with ZC-E0824 ("too many to check"), never skipped. No
  cluster comes near it; the supervisor is asked to confirm it in the slice's report, since a
  refusal is something an operator could in principle meet.
- **Plaintext.** Each opened record's plaintext is in a stack buffer, zeroed after the check.
  The key is wiped when the server stops.

Where: `docs/sealing.md`, `src/server_seal.zig` (`open`, `check`).
