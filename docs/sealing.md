# Sealed records (C5 slice 2)

The server seals the secrets it keeps in the store: certificate keys in `/edge-certs/<host>` and
ACME account keys in `/acme-account/<directory-hash>` (`docs/keys.md`). Slice 2 builds the
sealing and the key's lifecycle; slices 3b and 4a write the first sealed records. The design is
`docs/briefs/c5.md`, "Sealing and the key's lifecycle" and "Secrets never leave sealed".

## The envelope

`src/seal.zig` (core) seals at most `seal_plaintext_bytes_max` (512) bytes with
XChaCha20-Poly1305 and a random 24-byte nonce:

    zcseal1.<key id, 16 hex>.<base64url, no padding: nonce ‖ ciphertext ‖ tag>

The associated data is the header (`zcseal1.<key id>.`), a zero byte and the record's store key,
so a record copied to another key, or to another key id, does not open. A record's clear members
(chain, dates, state, key id) sit beside the envelope in the record's JSON. Rolling a record
back to an older sealed version of the same key is not detected; only a store writer can do it,
and store writers are trusted (the brief's accepted risk).

The key id is the first 8 bytes, in hex, of SHA-256 over `"zcube seal key id\0"` and the key: it
names a key without revealing it.

## The key file

32 random bytes, mode 0600, in the server's state directory beside the CA key and named after it:
`ca-<hash>.key` (SQLite) has `seal-<hash>.key`, and `ca.key` (Postgres) has `seal.key`. A memory
store's key has no file: its records end with the process. Only the server reads it, at start
(`src/server_seal.zig`, `open`). Back it up with the CA key: without it the sealed records are
lost.

## At start

After the store's first check and before the CA is loaded, the server reads every record under
`/edge-certs/` and `/acme-account/` and opens each envelope with the key:

- **No key and no sealed records** (a new cluster, or a C3 or C4 store): the key is made and
  written. Nothing else changes.
- **A key that opens every sealed record:** the server starts.
- **Sealed records and no key, or a key that does not open one** (another key, a moved record, a
  changed byte): the start is refused with **ZC-E0824**. Without `--verbose` it names the key id
  the records expect and the key file; `--verbose` also names the first record that did not open
  and why. No key is written. Fixes: restore the key file from a backup, or start once with
  `--discard-sealed`.

A value with no envelope is skipped: an entry not yet given a key holds nothing sealed.

## `zcube-server --discard-sealed`

The way out when the key is lost. It deletes every record under `/edge-certs/`, `/acme-account/`
and `/acme-orders/`, then makes and writes a new key, then prints **ZC-W0808** (with every cause:
the count, the new key's id and Let's Encrypt's limits) and starts. Every public host is then
ordered again, which counts against Let's Encrypt's limits: 50 certificates per registered domain
per week and 5 duplicates per week. Leave the flag out of later starts: with it, every start
discards again.

## Redaction

`src/testing/redaction.zig` looks for a planted secret in raw bytes, hex in either case and base64
(standard and URL-safe, at any alignment inside a longer string). Slice 2's test
(`src/server_test.zig`, "sealed records: ...") plants a sealed record and checks `/v1/list` of
every key, a watch from revision 1, `/v1/status` and ZC-E0824's text for the sealing key and the
plaintext. `zcube bundle` fetches `/v1/list`, `/v1/status` and `/v1/why` (the first two are
checked here) and never reads the state directory, so it never holds `seal-*.key` or `ca-*.key`.
