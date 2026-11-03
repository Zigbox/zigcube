# C1 slice 2: the writer table is code (src/writers.zig), checked by writers.txn(store, role, request, diag) as an assertion at every call site, so Store.txn is unchanged

*Decided 2026-10-30.*

C1 slice 2: the writer table is code (`src/writers.zig`), checked by `writers.txn(store, role, request, diag)` as an assertion at every call site, so `Store.txn` is unchanged. Departures from `authority.md` §2: a seventh role `retention` (deletes expired decisions, decision prefixes only); the replica controller may still put `/services/<name>` (never delete it) because C0 keeps `next_replica` there, until the counter gets a key of its own (Ask first); the node controller may delete `/observed/` records (§3). Stored values carry a version: `Observed` and `Decision` write v2, all else v1; a reader accepts every version up to its own and refuses a newer one with `ZC-E0303` (not E0301). A move has 8 compares (placement on the new node plus a release on the old), within the limit of 10.

Where: `src/writers.zig`, `src/records.zig`, `src/compare_sets.zig`, `docs/keys.md`, `docs/briefs/c1-2.md`
