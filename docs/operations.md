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
