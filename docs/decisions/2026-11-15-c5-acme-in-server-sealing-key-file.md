# ACME runs in zcube-server, and the sealing key is a file in its state directory

*Decided 2026-11-15, by the owner (C5 brief, Q3: (a) and (a)); recorded by the supervisor's docs
session.*

- **ACME client.** `zcube-server` talks to the ACME CA: the pure order machine in the core
  (`src/acme.zig`), the HTTP and the clock in the shell (`src/acme_shell.zig`). Edges only answer
  HTTP-01 challenges from the store.
- **Sealing key.** A 0600 file in the server's state directory, `seal-<hash>.key`, beside the CA
  key, never in the store, with the same backup rule as the CA key. Records under
  `/edge-certs/<host>` and `/acme-account/<directory-hash>` are sealed with it
  (XChaCha20-Poly1305, the key path as associated data). The ACME account key lives sealed in the
  store, one record per directory URL, not in the state directory. Edges receive unsealed
  certificate keys over mTLS and keep them in memory only.
- **Lifecycle** (supervisor ruling R6). With no sealed records, the server creates the key at
  start, so an upgrade from C3/C4 needs nothing. Sealed records with no key, or a key that does
  not open them, stop the server with ZC-E0824. `--discard-sealed` deletes the sealed records,
  makes a new key and warns (ZC-W0808) that every public host is reordered against Let's
  Encrypt's limits. Losing the key costs reorders, not data.
- **Key stores later, in C8.** Support for external key stores (cloud KMS and the like) for the
  sealing key is a later release's work, slotted into **C8** by the owner. C5 does not build it
  and does not shape an interface for it beyond keeping the key's loading in one shell function.

**Note.** C8 is "Jobs" in README.md and the site's milestone list, and C6 ("Trust") might seem the
nearer home for key stores. The owner named C8; this file records C8. C8's scope note in the
milestone list gains the item when C8's brief is written.

Where: `docs/briefs/c5.md` ("Where ACME runs", "Sealing", Non-goals).
