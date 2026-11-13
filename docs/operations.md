# Operating Zigcube

## Upgrading the store (schema version 1 to 2)

Schema version 2 adds the chain hash (`docs/store-design.md`, "The chain hash").

1. **Stop every v1 server**, and anything else that writes to the store. Do not run v1 and v2
   servers against one store, even for a moment.
2. Start one v2 server. It migrates the store when it opens it.
3. Start the others.

Why: a v1 server does not know the hash. If it writes after the migration, that revision has no
hash, and the v2 server reports the store as damaged (`ZC-E0209`, "has no hash for a revision").
The only way out is a restore from a backup. There are no rolling upgrades.

A migrated store has no hashes below the revision it was migrated at: `hash_at` there fails with
`ZC-E0214`, which says so. That is expected, not damage.

## Upgrading to C3's records (service and replica version 4, observed version 3)

C3 slice 5 adds `/history/` and `/rollouts/`, service and replica version 4 and observed
version 3 (`docs/keys.md`); the store schema does not change. Every record is written at the
oldest version that holds its members, so until a service carries `health` or a non-default
`rollout`, nothing new is written that an older build cannot read.

1. **Stop every older server, then start the servers of this release.** Do not run both against
   one store, even for a moment: an older server writes no history (its applies leave a gap, its
   deletes leave the old records, item 5), and an agent of this release that reports a health
   verdict to it is refused with a plain `ZC-E0104` (400: its observation endpoint takes no
   member it does not know), not `ZC-E0303`. A server of this release reads every older record
   (`src/testdata/b3_store.txt`), a C2 agent's version 2 observation included.
2. **Then upgrade the agents, one at a time if you like.** An older agent keeps working against
   this release as long as no replica it is served carries `health`.
3. **Apply no service with `health` or a non-default `rollout` until every agent is upgraded.**
   Either writes the service at version 4, and `health` its replicas too; an older agent refuses
   a version 4 replica with `ZC-E0303`, naming the key and both versions.
4. **History starts at the upgrade.** A service applied before it has no `/history/` record.
   The first apply after the upgrade that raises its generation records the generation it ran
   too, copied from the service record (`applied_at_ms` 0, not known), so that apply can be
   rolled back; nothing older can.
5. A downgrade is safe only while no record is at a new version. An older server leaves
   `/history/` and `/rollouts/` alone and writes no history, so after an upgrade back:
   - a service the older server **deleted** (and perhaps applied again) has the deleted service's
     history left behind. None of it is offered for a rollback, and the next apply of the name by
     this release deletes it.
   - a service the older server **changed** has a gap: the generations it applied have no
     record. Nothing from before the gap is offered for a rollback (it predates the downgrade),
     and the next apply deletes it. Until that apply, `zcube rollback` has nothing to go back to;
     that apply records the generation the older server left running, as in item 4.
   Records that do not fit in that apply's transaction are deleted by the following ones and are
   never offered meanwhile (docs/keys.md, `/history`).

## Postgres high availability: the supported setup

- **One primary.** Zigcube writes to one Postgres server and reads only from it. No reader
  endpoint, no pooler that routes reads to a replica.
- **High availability only through a synchronous standby**: `synchronous_commit = remote_apply`
  (or `on`), and the standby named in `synchronous_standby_names`. A failover to it loses no
  acknowledged commit, and the server carries on once its address points at the new primary (a
  virtual IP or a DNS name; the server has no multi-host connection string).
- **An asynchronous standby is not supported.** A failover to one that was behind loses
  acknowledged writes. The server notices (next section): it halts with `ZC-E0215`, which names
  both revisions, and acts on nothing until an operator decides.
- Both are run for real by `zig build test-store-faults -Dbackend=postgres` (`docs/demos/c1.md`).

## The server's memory of the store (`--state-dir`)

The server remembers the highest store revision and hash it has seen in `<state dir>/<db file name>.<16 hex digits>.remembered` (SQLite; `<state dir>/remembered` for Postgres),
so that a restart after a failover to a replica that was behind, or a restore from an old backup,
is noticed (`ZC-E0215`) and the server stops acting. The directory is `--state-dir`; for SQLite it
defaults to the directory of the database file; for Postgres it is required (`ZC-E0106` without
it). Keep it outside the store: a copy inside the store would be rolled back with it.

- **A restore must run `accept-rollback`.** A store restored from a backup is behind what the
  server remembers, so the server halts. Look at which store this is, then
  `zcube store accept-rollback --confirm`.
- **Pre-upgrade stores.** Hashes below the revision the schema was migrated at do not exist
  (`ZC-E0214`). A server that remembered a revision in that range cannot check it and halts;
  run `accept-rollback` once.
- A memory store remembers nothing and has no file.

**The file is keyed by the database's absolute path** (the working directory plus the name given,
no symlinks resolved; the hex digits are a hash of it), so two databases named `zcube.db` in
different directories can share one `--state-dir` and keep two pairs. The consequence: a database
restored **under a new path or name is a new database to the server**. It has no file, is not
checked, and starts a pair of its own. Restore an old backup *over the same path* (the case the
check exists for) and it is caught; to keep the check across a move, start the server with the
database at its old path, or copy the old `.remembered` file to the new name. A SQLite file name
longer than about 260 bytes is refused at start (`ZC-E0216`).
