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
