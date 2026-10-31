# Store design: revisions, watches and leases on Postgres and SQLite

The interface and its rules are in `src/store.zig`; `src/store_memory.zig` is the reference
implementation whose tests pin them down. This document says how the two real backends
realise the rules, and in particular how each assigns the global revision and how the Postgres
watch avoids the out-of-order-commit gap.

The schema works on **plain heap tables**. OrioleDB is an optional optimisation for one table
(see "OrioleDB").

## The model both backends share

One logical store is a log of events plus a table of live keys.

- `store_meta`: one row, `revision` (the current one) and `compacted_revision`.
- `store_log`: append-only. One row per event: `(revision, idx)` primary key, `key`, `deleted`,
  `value`, `create_revision`, `lease`. `idx` is the position inside the transaction, so a
  multi-key transaction is one revision with several rows, delivered together.
  Index on `(key, revision)` for history reads.
- `store_live`: the latest row per key: `key` primary key, `value`, `create_revision`,
  `mod_revision`, `lease`. Reads of current state and the compares of a `txn` use it; it is
  the hot, update-heavy table. Index on `lease` where non-zero.
- `store_lease`: `id`, `ttl_ms`, `deadline`.

Keys are `text` ordered bytewise (`COLLATE "C"` on Postgres, `BINARY` on SQLite), so a prefix
read is a range scan `key >= p AND key < p'` where `p'` is the prefix with its last byte
incremented. No `LIKE`, so no collation or escaping surprises.

Revision granularity: **one revision per committed transaction that changes a key**, shared by
its events. A watcher that has seen revision N resumes from N + 1 and cannot see half of a
revision, because a batch never splits one (a revision holds at most 64 events, a batch up to
256: `constants.zig` asserts it).

## Assigning the revision

### Postgres: serialise on the meta row

Every write transaction starts by taking the writer lock *and* the next revision in one
statement:

```sql
BEGIN;
UPDATE store_meta SET revision = revision + 1 RETURNING revision;   -- row lock, held to commit
-- evaluate compares against store_live, apply the chosen branch to store_log and store_live,
-- fire NOTIFY, all under the revision just taken
COMMIT;
```

The row lock is held until commit or rollback, so two writers cannot be in flight at once.
Consequences, which are the whole point:

1. **Revision order is commit order.** Writer B cannot obtain revision N + 1 until writer A,
   which holds N, has committed (or rolled back).
2. **No gaps, ever.** If A rolls back, its `UPDATE` rolls back too, so N was never consumed
   and B takes it. A sequence would have burned N. A transaction that turns out to change
   nothing (no event) also rolls back its bump instead of keeping it.
3. **Compares are race-free.** Compares and writes run under the writer lock, so a
   compare-and-swap needs no `SERIALIZABLE` retries and READ COMMITTED is enough.
4. **Visibility follows the same order.** Postgres removes a committing transaction from the
   set of in-progress transactions *before* it releases its locks. A statement snapshot that
   sees B's rows (revision N + 1) was therefore taken after A (N) stopped being in progress,
   so it sees A's rows too. A reader can never observe revision N + 1 without N.

Cost, stated plainly: all writers are serialised for the length of their transaction (a few
statements, a millisecond or two on a local database). That caps write throughput at some
hundreds to low thousands of revisions per second. The fleet this targets in C0 and C1 (a
few hundred nodes, observed state reported about once per second per node, a few hundred
decision writes per second at most) is inside that. The risk table in SPEC.md already asks
for a benchmark at C1. If it bites: the server groups concurrent requests into one transaction
(group commit, one revision per group), which changes nothing above the interface except that
unrelated writes share a revision.

**Defence in depth.** The watch reader also checks contiguity: the revisions it reads must be
exactly `cursor + 1, cursor + 2, ...`. If it ever sees a hole, it re-reads after a short
delay a bounded number of times, and then raises a `bug` diagnostic (`ZC-B0001`) rather than
skip an event silently. The conformance suite asserts the same property under concurrent
writers.

### SQLite: the single writer is the serialisation

A write transaction is `BEGIN IMMEDIATE`, which takes SQLite's one write lock; it then does
the same `UPDATE store_meta ... RETURNING revision` and the same steps. With WAL, readers see a
consistent snapshot and never block the writer. Commit order is revision order because only
one transaction can write at a time. Writes from a second process are not supported while the
server runs (the server is the only store client; agents and the CLI use the API).

### What both rely on

The revision is incremented inside the same transaction as the data it labels. There is no
separate sequence, no clock, and no state held only in the server's memory.

## Watches

`Watch.next` returns events with `mod_revision >= position`, ordered by `(revision, idx)`, and
a `revision` bookmark. On Postgres the query is:

```sql
SELECT m.revision AS bookmark, l.*
FROM store_meta m
LEFT JOIN store_log l ON l.revision >= $position AND l.key >= $p AND l.key < $p_end
ORDER BY l.revision, l.idx LIMIT $batch_max + 1;
```

Reading the bookmark and the rows in **one statement** means they share a snapshot: every
matching event up to `bookmark` is in the result or an earlier batch. If the limit cut a
revision in half, the trailing partial revision is dropped from the batch (a revision always
fits). If the table's `compacted_revision` is at or past `position`, the answer is
`Compacted`. A watch that is idle still returns the bookmark, so it can reconnect without a
relist.

Waking waiters: the writer sends `NOTIFY zcube_store, '<revision>'` inside its transaction
(delivered at commit, in commit order). The server holds one `LISTEN` connection and one
latest-revision counter; sleeping `next` calls wake when it moves, with a poll tick as a
fallback so a lost notification costs latency, not correctness. SQLite has no `NOTIFY`: the
server signals the same counter in-process after `COMMIT`, plus the poll tick.

Fan-out is the part to measure at C1: every waiting watch runs its own indexed query per
wake-up. The planned optimisation, if needed, is a ring buffer of the most recent events fed by
one reader and shared by all watches, with the table as the fallback for a watch that is
behind the ring. It changes nothing above the interface.

## Leases

`lease_grant` inserts a row with `deadline = now + ttl`; `lease_keepalive` moves the deadline
to `now + ttl` and fails with `LeaseNotFound` if the deadline has passed (expiry is checked at
the moment of the call, before the reaper runs). On Postgres `now` is the database's
`clock_timestamp()`, so two servers on one database agree and a server clock step does not
shorten a lease; on SQLite it is the injected `Clock`. A put with a `lease` checks the lease
is alive in the same transaction.

`expire_leases` runs on a timer in the server. For each expired lease it takes the writer lock
and one revision, deletes every key with that lease (from `store_live`, writing a tombstone row
per key to `store_log`) and removes the lease. Watchers therefore see ordinary delete events;
the node controller reacts to `/nodes/<node>` disappearing like any other change.

## Compaction

`compact(R)` first sets `compacted_revision = R` under the writer lock (instantly making older
reads fail), then deletes in bounded batches, without the writer lock:

```sql
DELETE FROM store_log l
WHERE l.revision <= $R AND (l.deleted OR EXISTS (
    SELECT 1 FROM store_log n WHERE n.key = l.key AND n.revision > l.revision AND n.revision <= $R))
```

That keeps the latest put per key at or below `R` and everything above it, so a read at `R`
or later is unchanged. A historical read re-checks `compacted_revision` after it finishes and
fails with `Compacted` if it moved above the read's revision, so it never returns a half-pruned
answer. The server compacts on a schedule to a revision a configurable window behind the head
(default: a few minutes of history, enough for a restarting agent to resume rather than relist).

## The chain hash

Every revision carries a hash that commits to the whole history before it:

```
h(0) = 32 zero bytes
h(n) = SHA-256( h(n-1) || u64be(n) || event_1 || ... || event_k )
event = kind u8 (1 put, 2 delete) || u32be(len key) || key || u32be(len value) || value
        || u64be(create_revision) || u64be(lease)
```

The events are the revision's events in position order (`idx`). A delete event has an empty
value and carries the create revision and lease of the key it removed. A transaction that
changes nothing takes no revision and has no hash. The hash is computed by one Zig function,
`ChainHasher` / `chain_hash` in `store.zig`, which is core code (wasm-clean); no backend hashes
in SQL, so all three produce the same bytes (the conformance suite pins `h(4)` of a fixed
history). Hashes are small (32 bytes per revision) and are never compacted away.

**Stored with the revision.** Memory keeps a hash list indexed by revision. SQLite and Postgres
have `store_hash(revision, hash)`, one row per revision, inserted in the same transaction as the
revision's log rows (Postgres: before `NOTIFY` and commit), so a revision never exists without
its hash. Writers are already serialised, so the previous hash is read once after the revision
is taken. `Store.status` returns the current hash and `Store.hash_at(revision)` any other.

**Upgrade (schema version 2).** A version 1 store has no hash and its older history may be
compacted, so it cannot be hashed retroactively. The migration adds `store_hash` and
`store_meta.chain_start`, sets `chain_start` to the revision it ran at and records
`h(chain_start) = SHA-256("zcube chain seed 1" || u64be(chain_start))`. From there the chain
continues as normal. `hash_at(r)` for `0 < r < chain_start` fails with `NoHash` (ZC-E0214, the
cause names `chain_start`); `hash_at(0)` is always zero and a revision above the head is
`FutureRevision`. A store migrated at revision 0 is the same as a new one. The upgrade is tested
from a store written by the previous schema on SQLite and Postgres.

**Stop every v1 server before a v2 server upgrades the store.** The migration seeds the chain at
the revision it ran at; a version 1 server knows nothing of `store_hash`, so a v1 write after the
migration commits a revision with no hash. The v2 server then finds a revision without a hash and
reads the store as damaged (ZC-E0209, "has no hash for a revision"), and nothing in the store says
which writer was to blame. The schema version does not stop it: v1 servers do not check it
against a newer one. So the operator stops all v1 servers (and anything else that writes to the
store) first, starts one v2 server to migrate, and only then starts others. Rolling upgrades
are not supported. See `docs/operations.md`.

## OrioleDB

`store_live` takes the update churn (every observed-state report overwrites a row). When the
`orioledb` extension is present, the migration creates **`store_live` `USING orioledb`**;
otherwise heap. `store_log` is append-only and stays heap; `store_meta` is a one-row hot spot
that stays heap, since its job is the lock. The schema, indexes, queries and the writer lock
are identical either way, which is what "must work on heap" requires. HANDOFF says to create
"the observed and decision tables" `USING orioledb`; in a generic key-value store those are key
ranges inside `store_live`, not tables, so my reading is to apply it to the one table that
holds them. If you want them physically separate, that is a key-routing layer and a layout
decision for you (see `docs/contracts-review.md`).

## SQLite as built (C0 slice 2)

`src/store_sqlite.zig` follows the design above, with these differences of detail:

- **Revision.** Inside `BEGIN IMMEDIATE` the revision is read, the ops are applied under
  `revision + 1`, and `store_meta` is updated once, just before `COMMIT`. A transaction that wrote
  nothing is rolled back instead, so it never takes a revision. This replaces the
  `UPDATE ... RETURNING` of the Postgres sketch; the effect is the same.
- **Reads.** `get`, `list` and the watch poll run in one deferred read transaction and read
  `store_meta` first, so the revision they report and the rows they return share a snapshot. A
  historical read therefore needs no re-check of the compaction point afterwards: compaction
  lowers the floor in one write and prunes in later ones, and a snapshot sees either none of it or
  the floor with the old rows still present.
- **Watch.** `next` polls every `constants.store_watch_poll_ms` until events appear or its timeout
  passes, and sleeps outside the connection mutex. It reads at most one batch plus one row; if the
  extra row belongs to a revision whose events were cut, that revision is dropped from the batch
  and the bookmark is the revision before it.
- **Leases.** The deadline is stored in `store_lease` on the injected `Clock`. It outlives the
  process, so the production clock for SQLite must be wall time in milliseconds; a monotonic clock
  that restarts at boot would make every lease look expired or immortal after a restart.
- **Compaction.** The first write sets `compacted_revision`; the rest deletes
  `constants.store_compact_batch_rows` rows per write transaction until none are left.
- **Failures.** `SQLITE_BUSY` after `store_sqlite_busy_ms` is ZC-E0208; `CORRUPT` or `NOTADB`, an
  empty file opened without `create`, and a file of another application are ZC-E0209; a newer
  `PRAGMA user_version` is ZC-E0210; `CANTOPEN` is ZC-E0201; anything else (I/O, full disk,
  read-only) is ZC-E0202. The raw message and code are the first cause; the last cause is for the
  operator.
- **Not done:** `NOTIFY`-style wake-ups (SQLite has none; the server will signal an in-process
  counter after `COMMIT` when it exists), a ring buffer shared by all watches, and any
  benchmark. All three are for C1.

## Postgres as built (C0 slice 3)

`src/store_postgres.zig` (the store) and `src/pq.zig` (libpq, parameters, results, failures)
follow the design above, with these differences of detail. Each is also in the slice report.

- **Revision.** As designed: `UPDATE store_meta SET revision = revision + 1 RETURNING revision`
  opens every write, READ COMMITTED, compares under the lock. A transaction that wrote no event
  rolls back. `lease_revoke` of a lease with no keys must still delete the lease row, so it
  subtracts its bump before committing instead (the lock is still held, so nothing can see the
  difference).
- **Reads** (`get`, `list`, the watch read, `status`) are one statement each: the meta row, and
  the data `LEFT JOIN`ed to it, so the revision and the rows share a snapshot without a
  `REPEATABLE READ` transaction. A page also ends at `store_page_bytes_max`: the statement sends
  a NULL value for rows past it, so libpq never holds more than a page of values.
- **Watch.** Each watch has a connection of its own and `LISTEN`s on `zcube_<schema>` before its
  first read. `next` reads, and if nothing is there waits on the socket for a notification, at
  most `store_watch_notify_fallback_ms` (250 ms: the bound on what a lost notification costs;
  SQLite's `store_watch_poll_ms` is 10 ms because it has nothing else). Postgres allows
  `store_postgres_watches_max` (64) watches per store, not 256, because each holds a connection.
  A notification is only a hint: the read happens after every wake-up whatever woke it.
- **Contiguity check.** A watch filters by prefix, so the revisions it delivers are not
  contiguous; the check therefore counts distinct revisions in the log over the range the batch
  covers, whatever their keys, in a second statement. A mismatch is first compared with the
  compaction point (a compaction that overtook the watch is `Compacted`, not a hole), then
  re-read up to `store_watch_hole_retries_max` times, then ZC-B0001. A test makes a hole by
  moving a revision's rows out of the log.
- **Leases and time.** `OpenOptions.lease_time` is `.database` (Postgres's `clock_timestamp()`,
  read inside the statement that stores or compares the deadline; two servers agree) or
  `.clock` (an injected `Clock`, which the conformance suite uses so lease expiry needs no
  sleeping). The contract's "the time is the backend's" holds in production; the seam is
  explicit in the options and a deadline written under one means nothing under the other.
  `lease_grant` takes an advisory lock so the lease-count limit cannot be overfilled by
  concurrent grants.
- **Schema identity** is a row, not a pragma: `store_meta` carries `application` and
  `schema_version`. Opening takes an advisory lock, so servers starting together initialise an
  empty schema once. A schema that holds other relations, or whose `store_meta` names another
  application, is ZC-E0209; a higher `schema_version` is ZC-E0210; nothing is created without
  `create`. The schema (`zcube` by default) is a setting, so several stores can share a database.
- **OrioleDB.** On creation the catalogue is asked whether `orioledb` is installed or
  available; `store_live` is `USING orioledb` if it is installed, or if `CREATE EXTENSION`
  (in a savepoint, so a refusal costs nothing) succeeds. The decision (`plan_access`) and the
  DDL (`schema_sql`) are tested; the extension itself has not been run, and the upsert
  (`INSERT ... ON CONFLICT`) that `store_live` relies on is untested on OrioleDB tables.
- **Connections.** At most `store_postgres_connections_max` (8) per store, one per operation in
  flight, opened lazily. Each connection sets `search_path`, `lock_timeout`,
  `statement_timeout` and `idle_in_transaction_session_timeout` (so a server that dies holding
  the writer lock frees it in 30 s, not when TCP notices). A dead idle connection is replaced
  before an operation begins; one lost inside a transaction is ZC-E0213, which says whether the
  commit's outcome is unknown.
- **Compaction** batches are ordered oldest first (`ORDER BY revision, idx`). Without the order a
  batch could prune a tombstone while leaving the older puts of its key, which a historical read
  would then return as live. The SQLite statement has no `ORDER BY` and relies on the scan order
  of its primary key.
- **Failures.** A connection that cannot be made is ZC-E0201 (refused, no route, bad settings),
  ZC-E0211 (credentials) or ZC-E0212 (no such database). libpq reports no SQLSTATE for these, so
  `classify_connect` matches Postgres's English text and falls back to ZC-E0201, whose first cause
  is always the raw message. After connecting, SQLSTATEs decide: lock timeout, deadlock,
  serialisation failure and statement timeout are ZC-E0208; a missing table or column is
  ZC-E0209; a lost connection is ZC-E0213; everything else is ZC-E0202.
- **Not done:** the ring buffer shared by all watches, group commit, and any benchmark
  (all C1). A result is held whole by libpq, so a watch batch of 256 events can briefly hold
  256 values; only list pages are bounded in bytes.

## k3s's kine: what I take and what I leave

kine presents an etcd API on SQL. This section is from my knowledge of its design, not from
reading its source in this session, so check specifics before relying on them.

Taken:

- **An append-only log table where the row id is the revision**, with a `prev_revision` and
  delete tombstones, so history, watch and compaction are all queries over one table.
- **Watch as a cursor poll** over that table, woken early by `NOTIFY` on Postgres, instead of
  logical decoding or triggers. It is simple, works on heap tables and on SQLite, and has no
  extension to install.
- **Compaction that keeps the latest row per key**, run in batches so it never holds a long
  lock.

Left:

- **Revision from a sequence or autoincrement.** That is exactly the hazard HANDOFF names:
  ids are handed out before commit, so they commit out of order and roll back with holes.
  kine's answer, as I remember it, is to detect a hole while polling, wait a short time for the
  late transaction, and then insert a filler row to close the gap. That costs a latency floor,
  extra writes, and a timing assumption (how long can a transaction legitimately take?) that
  can be wrong. Serialising on the meta row removes the hazard instead of repairing it, at the
  price of write throughput that this fleet size does not need.
- **TTL on a key as the lease.** Node registration needs a real lease with keepalive, shared
  by several keys and revoked in one revision, as the interface says.
- **A schema shaped like etcd's KV.** Ours has `idx` so that a transaction is one revision, and
  a separate `store_live` so the hot table can be OrioleDB.
