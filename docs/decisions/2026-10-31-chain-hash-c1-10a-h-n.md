# Chain hash (C1 10a): h(n) = SHA-256(h(n-1) \|\| revision \|\| events), computed only in store.zig, stored in the revision's transaction; schema version 2 seeds the chain at the upgrade revision, and hash_at below it is ZC-E0214 (NoHash), not Compacted.

*Decided 2026-10-31.*

Chain hash (C1 10a): `h(n) = SHA-256(h(n-1) \|\| revision \|\| events)`, computed only in `store.zig`, stored in the revision's transaction; schema version 2 seeds the chain at the upgrade revision, and `hash_at` below it is ZC-E0214 (`NoHash`), not `Compacted`.

Where: `docs/store-design.md`
