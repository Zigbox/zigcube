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
