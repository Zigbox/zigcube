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

The key is written without replacing a file: if two starts race to make it, the second reads the
first one's key instead of writing its own (the CA key is not written this way; see
`docs/decisions/2026-11-18-c5-seal-fix-discard-and-find.md`).

Two Postgres stores served from one state directory share `seal.key`, as they share `ca.key`:
neither file's name tells the stores apart. Give each Postgres store its own `--state-dir`; a
start whose store was sealed with the other store's key is refused with ZC-E0824.

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

Every envelope in a value is opened, not only the first. An envelope is `zcseal`, a version in
digits, a dot, a 16-hex key id and a dot, followed by base64url; text that is not of that shape
(a host named `zcseal1.example.com`, say) is not one. An envelope of another version is refused
as one this server cannot read. A value with no envelope is skipped: an entry not yet given a key
holds nothing sealed.

The check reads at most 2,048,000 records under each prefix (`seal_scan_pages_max`, 4096 pages of
`store_list_limit_max`, 500). Past that the start is refused with ZC-E0824 ("more than 2048000
records under ..."), whose fix is to delete the records no public host uses any more: the server
does not start over records it has only partly checked, and `--discard-sealed` is not the remedy
(it would delete every one of them).

## `zcube-server --discard-sealed`

The way out when the key is lost. The flag acts only when the start check fails (sealed records
and no key, or a key that does not open one). With a key that opens every sealed record it does
nothing: no record is deleted, the key is kept, and ZC-W0808 says "nothing to discard; remove
--discard-sealed".

When it acts, the discard is planned during the check and carried out only after every start step
that can refuse (the CA, the listeners), so a refused start deletes nothing. Then, in order:

1. Every record under `/edge-certs/`, `/acme-account/` and `/acme-orders/` is deleted.
2. The old key file, if there is one, is renamed `<key file>.discarded-<unix seconds>` (for
   example `seal-0123456789abcdef.key.discarded-1763424000`, or `seal.key.discarded-...` for
   Postgres), still 0600, never over another file.
3. A new key is made and written.
4. **ZC-W0808** is printed (with every cause: the count, where the old key went, the new key's id
   and Let's Encrypt's limits) and the server starts.

Every public host is then ordered again, which counts against Let's Encrypt's limits: 50
certificates per registered domain per week and 5 duplicates per week. Leave the flag out of
later starts.

If something else keeps writing under a prefix (another `zcube-server` on the same store), the
deletes cannot finish: the start ends with ZC-E0824 ("--discard-sealed could not empty ..."), the
old key file is left where it was, and the fix is to stop the other writer and start again.

### Restoring a discarded key

The sealed records are gone once the discard has run, so the old key opens nothing in this store.
It still opens a backup of the store taken before the discard. To go back to that backup:

1. Stop the server.
2. Restore the store from the backup.
3. In the state directory, move the new key aside and put the old one back, keeping mode 0600:

       mv seal-<hash>.key seal-<hash>.key.new
       mv seal-<hash>.key.discarded-<seconds> seal-<hash>.key
       chmod 600 seal-<hash>.key

4. Start the server without `--discard-sealed`. The start check confirms the key opens the
   restored records, or refuses with ZC-E0824.

## Redaction

`src/testing/redaction.zig` looks for a planted secret in raw bytes, hex in either case and base64
(standard and URL-safe, at any alignment inside a longer string), in the output as it is and with
whitespace and the JSON escapes `\n`, `\r`, `\t` and `\/` taken out, so base64 wrapped at 64 or
76 columns (PEM) or escaped in a JSON string is found too. Slice 2's test
(`src/server_test.zig`, "sealed records: ...") plants a sealed record and checks `/v1/list` of
every key, a watch from revision 1, `/v1/status` and ZC-E0824's text (plain, `--verbose` and JSON,
in `src/server_seal.zig`'s tests) for the sealing key and the plaintext; as a negative control it
then writes the plaintext in base64 into a record of its own and the harness must find it in the
same replies. `zcube bundle` fetches `/v1/list`, `/v1/status` and `/v1/why` (the first two are
checked here) and never reads the state directory, so it never holds `seal-*.key` or `ca-*.key`.
