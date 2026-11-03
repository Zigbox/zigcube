# Postgres as the store, with rules (owner, after weighing Jepsen's Postgres findings): one primary, high availability only through a synchronous standby, never a read from a replica; every commit carries a chain hash and every client refuses a store that went backwards or forked; and a store fault proxy (our own, Toxiproxy-style, in Zig: no new dependency) with a history checker and a failover test is C1 slice 10, its test a ship gate

*Decided 2026-10-30.*

Postgres as the store, with rules (owner, after weighing Jepsen's Postgres findings): one primary, high availability only through a synchronous standby, never a read from a replica; every commit carries a chain hash and every client refuses a store that went backwards or forked; and a store fault proxy (our own, Toxiproxy-style, in Zig: no new dependency) with a history checker and a failover test is C1 slice 10, its test a ship gate. Brings the Postgres fault proxy forward from "Later, not in 2b". Why not etcd, FoundationDB, a Raft store of our own or SQLite: the risk Jepsen found is in replication and failover, which these rules close, at far less cost than a new store.

Where: `docs/briefs/c1.md`
