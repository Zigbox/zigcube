# The sealed envelope and the sealing key's file

*Decided 2026-11-18, by the slice (C5 slice 2).* It builds on
`2026-11-15-c5-acme-in-server-sealing-key-file.md`; slice 2 starts from main as
`2026-11-18-c5-early-slices-from-main.md` allows.

- **Envelope.** `zcseal1.<key id>.<base64url-no-pad(nonce ‖ ciphertext ‖ tag)>`, a string inside
  the record's JSON, so a record keeps its clear members beside it and the start-up check finds
  it by its magic without knowing the record's schema. The associated data is the header, a zero
  byte and the store key: a moved record, and a record whose key id was edited, do not open. The
  version is in the magic (`zcseal1`), so a later format can live beside this one.
- **Key id.** The first 8 bytes of SHA-256 over a fixed label and the key, as 16 hex digits. It
  is in the clear header so that ZC-E0824 can say which key the records expect; it reveals
  nothing of the key.
- **Plaintext bound.** `seal_plaintext_bytes_max` = 512 (internal): a P-256 key in DER is under
  140 bytes.
- **The file's name follows the CA key's,** with `ca` replaced by `seal`: `seal-<hash>.key` beside
  SQLite's `ca-<hash>.key`, and `seal.key` beside `ca.key` (Postgres). The brief says
  `seal-<hash>.key`; for Postgres, whose CA key has no hash, the name follows the CA's so that
  one store's two keys always sit together. Made with `secure_random.fill`, written 0600 by
  `files.write_seed`, read by `files.read_seed` (the CA key's own helpers).
- **A memory store has no key file,** even with a state directory: its records end with the
  process, so a key that outlived them would only be another secret on disk.

Where: `docs/sealing.md`, `src/seal.zig`, `src/server_seal.zig`.
