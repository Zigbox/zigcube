# `--discard-sealed`, the scan's bound and the envelope search, after review

*Decided 2026-11-18, by the supervisor's rulings on PR #284's review (C5 slice 2); recorded by
the fix session. It refines `2026-11-18-c5-seal-start-check.md` and
`2026-11-18-c5-seal-discard-order.md`, which stand where this file does not say otherwise.*

## `--discard-sealed` (ruling 1)

- **Only when the check fails.** The flag acts only when the start check refuses: sealed records
  and no key, or a key that does not open one. With a key that opens every sealed record, nothing
  is deleted, the key file is not touched, the start goes on, and ZC-W0808 says "nothing to
  discard; remove --discard-sealed". W0808 is the existing code with new text; its summary is now
  "the server started with --discard-sealed", which fits both.
- **Planned first, carried out last.** `server_seal.open` (before the CA, as before) only plans
  the discard: it returns `.discard` and deletes nothing. `server_seal.discard`, called from
  `Server.finish_seal` after the CA and the listeners have opened and just before the server's
  tasks are spawned, carries it out. A start refused by the CA or a listener deletes nothing and
  leaves the key file as it was.
- **The old key is never overwritten.** The discard's order is: delete the records under
  `/edge-certs/`, `/acme-account/` and `/acme-orders/`; rename the old key file to
  `<key file>.discarded-<unix seconds>` (`seal-<hash>.key.discarded-...`, or
  `seal.key.discarded-...` for Postgres) with no-replace semantics (`renameat2(RENAME_NOREPLACE)`,
  or a hard link and an unlink where the file system lacks it), mode unchanged (0600), and sync
  the directory; then make and write the new key; then warn. A crash part way leaves the old key
  and fewer records, or the old key aside and no key and no records: the next start is never
  worse off. `docs/sealing.md` says how to restore an aside key with a backup of the store.

## The 4096-page bound (ruling 2)

- **The numbers.** The start check reads at most `seal_scan_pages_max` (4096) pages of
  `store_list_limit_max` (500) records under each prefix: **2,048,000 records per prefix**
  (`server_seal.scan_records_max`, asserted at compile time).
- **The refusal** is ZC-E0824 with one cause naming the bound and the prefix ("more than 2048000
  records under /edge-certs/; the start-up check reads at most 2048000 (4096 pages of 500) ...")
  and one fix: delete the records no public host uses any more. It never suggests
  `--discard-sealed`, which would delete every one of them. With the flag, the same bound is
  checked (counting every discarded prefix, `/acme-orders/` included) before the discard is
  planned, so a planned discard is one that can finish.
- **The discard's rounds** come from the same constants: `ceil(scan_records_max /
  store_txn_ops_max)` rounds of 16 deletes, plus one failed compare per page
  (`seal_scan_pages_max`), so a prefix within the bound always empties unless something else keeps
  writing there.
- **A discard that cannot finish** (records kept appearing: another writer) is ZC-E0824 with
  its own cause ("--discard-sealed could not empty ...; another writer is at work; the old key
  file is unchanged") and the fix "stop every other zcube-server on this store, then start
  again". It does not tell the operator to use the flag they are using. **No new code.**

## Finding envelopes (ruling 3)

- `seal.envelopes(value)` returns every envelope in a value, and the start check opens each one
  (it used to stop at the first). A candidate must have the header's whole shape: `zcseal`, 1 to
  9 digits, a dot, 16 lowercase hex digits, a dot. Text without that shape is not an envelope, so
  a clear member such as a host named `zcseal1.example.com` neither hides a later envelope nor
  fakes one. A header of another version (`zcseal2.`) is returned, and `open` refuses it as
  Malformed: a record this build cannot read is refused, not skipped.
- **Accepted:** a header whose key id is damaged (not 16 lowercase hex) is not of the shape and
  is skipped. Changing an envelope in place needs a store writer, who is trusted (the brief's
  accepted risk); every other change to an envelope's bytes is refused as Forged or Malformed.
- Known-answer tests pin the envelope and key id for a fixed key, nonce, path and plaintext, and
  `Aead` is checked against draft-irtf-cfrg-xchacha-03's A.3.1 vector.
- The redaction harness also searches the output with whitespace and the JSON escapes `\n`, `\r`,
  `\t` and `\/` taken out, so base64 wrapped at 64 or 76 columns (PEM) or escaped in JSON is
  found. The server's redaction test has a negative control: the plaintext written in base64 into
  a record of its own must be found in the same replies.

## The key file (ruling 4)

- The sealing key is written with no-replace semantics (`peer_files.write_seed_new`): staged
  0600, then renamed into place only if no file is there. If another start wrote one meanwhile,
  that key is read and used, so two racing starts agree on one key.
- **The CA key is left alone** (the ruling): it is still written as before
  (`peer_files.write_seed`), and whether its creation should get the same no-replace treatment is
  left to a later change.
- Two Postgres stores served from one state directory share `seal.key`, as they share `ca.key`;
  `docs/sealing.md` says to give each its own `--state-dir`.

Where: `src/server_seal.zig` (`open`, `discard`, `walk`, `raise_too_many`, `raise_unfinished`,
`render_nothing`), `src/server.zig` (`open_seal`, `finish_seal`), `src/seal.zig` (`envelopes`),
`src/peer_files.zig` (`write_seed_new`, `rename_new`), `src/testing/redaction.zig`,
`docs/sealing.md`.
