# Store rollback guard (C1 10b): VerifiedStore is a core wrapper that halts the server with ZC-E0215 on a lower revision, a different hash_at(remembered) or NoHash (fail closed); no automatic recovery, the way out is zcube store accept-rollback --confirm

*Decided 2026-10-31.*

Store rollback guard (C1 10b): `VerifiedStore` is a core wrapper that halts the server with `ZC-E0215` on a lower revision, a different `hash_at(remembered)` or `NoHash` (fail closed); no automatic recovery, the way out is `zcube store accept-rollback --confirm`. The pair persists to `<state dir>/remembered` (`--state-dir`, else the SQLite file's directory; Postgres requires it, `ZC-E0106`); an unreadable file is `ZC-E0216`. Known gaps: `Watch.next` is not gated on a halt; the decision record with both pairs needs a store-level `SubjectKind` (keys.md, ask-first).

Where: `docs/store-design.md`, `docs/operations.md`
