# Deploying Zigcube for the Jepsen battery

What the battery's harness (`Zigbox/zigcube-jepsen`) runs on its Google Cloud hosts, over SSH, as
root. The faults and what each means for the checker are in `docs/jepsen.md`, "Faults"; the
cluster's shape is in docs/briefs/c5.md, "Jepsen on Google Cloud". Every script is idempotent and
non-interactive, and says its commands in its header.

The tarball holds these files under `share/jepsen/`, beside `bin/` (`zcube`, `zcube-server`,
`zcube-agent`, `zcube-jepsen-client`) and `COMMIT`. `zig build dist` makes it in `zig-out/dist`:
`zigcube-<version>-<commit>-x86_64-linux.tar.gz` and its `.sha256`. The executables are x86_64,
baseline CPU, and need glibc 2.39 or newer (Ubuntu 24.04), `libsqlite3-0` and `libpq5`.

## The order

Hosts: `pg1` and `pg2` (Postgres), `server`, `n1`…`nN` (agents), and the control host the
harness runs on. `CIDR` is the subnet they share. Copy the tarball and its `.sha256` to every
host, and the scripts from it (`tar -xzf T --strip-components=2 '*/share/jepsen'`) to `pg1` and
`pg2`, or install the tarball there too.

1. Every host: `zigcube.sh install /tmp/zigcube-….tar.gz` (also installs `iptables`).
2. `pg1`, `pg2`: `postgres.sh install`.
3. `pg1`: `postgres.sh primary --allow CIDR`.
4. `pg2`: `postgres.sh standby pg1 --allow CIDR`.
5. `pg1`: `postgres.sh sync-on` (waits for the standby, then requires it: every commit is
   applied on both before it is acknowledged).
6. `server`: `zigcube.sh server "postgres:host=pg1,pg2 port=5432,5432 user=zcube dbname=postgres
   target_session_attrs=read-write" 0.0.0.0:7070`. It writes `/etc/zcube/ca.crt` and the admin
   client certificate `/etc/zcube/client/jepsen.{crt,key}`.
7. `server`, for each node: `zigcube.sh node-cert nI`; copy `/etc/zcube/ca.crt` to `nI`'s
   `/etc/zcube/ca.crt` and `/etc/zcube/nodes/nI.{crt,key}` to its `/etc/zcube/node.{crt,key}`.
8. Each `nI`: `zigcube.sh agent nI SERVER_IP:7070 CPU_MILLIS MEMORY_BYTES`.
9. The control host gets `ca.crt` and `client/jepsen.{crt,key}`, and runs
   `zcube-jepsen-client … --server SERVER_IP:7070 --ca ca.crt --cert jepsen.crt --key jepsen.key`
   (the server's certificate names `zcube-server`, the default `--tls-name`).

The client and node certificates live 7 days; `client-cert jepsen --replace` and
`node-cert nI --replace` re-issue them.

Every step may be run again. `install` of another tarball (another name, or the same name with
another `.sha256`) unpacks it afresh, points `/opt/zigcube/current` at it and restarts whichever
of `zcube-server` and `zcube-agent` is running; the same tarball again changes nothing.
`server` with another STORE or LISTEN rewrites its configuration and re-issues `jepsen`'s
certificate from the CA of the new store (each store has its own CA: `ca.crt` for Postgres and
memory, `ca-<hash>.crt` for SQLite). `ops/jepsen/test-recipe.sh` and `test-postgres.sh` test
these scripts on one host (CI's `jepsen` job runs both, on the tarball's executables).

## Postgres failover

`postgres.sh crash` on the primary kills it (SIGKILL: no checkpoint, no shutdown). Then, on the
standby, `postgres.sh promote`: it becomes a primary that runs alone, synchronous with nothing.
The server's store follows it through libpq's host list. The old primary must never start again
as a primary (two primaries would each accept writes): `postgres.sh primary` refuses an existing,
stopped primary unless given `--restart`, which is for a primary whose standby was not promoted.
It rejoins as the new primary's standby, from a fresh base backup:
`postgres.sh standby pg2 --allow CIDR --rebuild`, then `postgres.sh sync-on` on `pg2`.

While the synchronous standby is down or cut off, every commit waits for it: the store's writes
stall (and time out as ZC-E0213), which is the price of losing nothing on failover.

## Not here

Nothing in this directory runs Google Cloud or the harness: making the hosts, copying files, and
running the operations and the checker are the harness's.
