# Failover (C1 10d): the failover runs make their own primary and streaming standby with pg_dev pair-up sync\|async (local Postgres 16 programs, in CI too; the service container stays for 10c), and move the server and clients to the promoted standby by repointing a fault proxy (Proxy.repoint), not with a multi-host connection string

*Decided 2026-11-02.*

Failover (C1 10d): the failover runs make their own primary and streaming standby with `pg_dev pair-up sync\|async` (local Postgres 16 programs, in CI too; the service container stays for 10c), and move the server and clients to the promoted standby by repointing a fault proxy (`Proxy.repoint`), not with a multi-host connection string. The asynchronous run makes the loss certain by partitioning replication and asserting the promoted revision is below the server's remembered one.

Where: `docs/briefs/c1-10d.md`, `docs/demos/c1.md`
