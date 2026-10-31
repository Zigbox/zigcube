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

The server remembers the highest store revision and hash it has seen in `<state dir>/remembered`,
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

