# Jepsen J2: the dist tarball and the deployment recipe

Date: 2026-11-17. Status: accepted (supervisor, 2026-11-17). These are the test recipe's
defaults, not the product's.

J2 (docs/briefs/c5.md, "Jepsen on Google Cloud", items 1, 2 and 4) adds `zig build dist`,
`ops/jepsen/` and docs/jepsen.md's "Faults". The choices it made:

1. **glibc 2.39 is the floor.** The server links the build host's libsqlite3 and libpq (Ubuntu
   24.04's), which need `fmod@GLIBC_2.38`; at 2.36 the link fails. So the executables need
   Ubuntu 24.04 or newer, and the battery's images must be that. A static SQLite and libpq would
   lower it, at the cost of building both; not done.
2. **`-Ddist-lib-dir`** (default `/usr/lib/x86_64-linux-gnu`) names where those libraries are
   linked from, since a cross target does not search the host's directories.
3. **The tarball's name carries the commit** (`zigcube-<version>-<commit12>[-dirty]-x86_64-linux`)
   and holds `share/jepsen/` (the recipe) and `COMMIT` beside `bin/`: the harness deploys one file
   and can tell which commit it tests. `-dirty` marks a build from a tree whose tracked files
   differ from HEAD; a dirty tarball is never a battery result.
4. **Reproducible bytes**: entries in a fixed order, mtime 0, uid and gid 0, no owner names, a
   gzip header without time or name. Two builds of one commit compare equal.
5. **`zig-out/dist` regardless of `--prefix`**, and it deletes the `zigcube-*` files an earlier
   run left there, so it holds one tarball.
6. **Postgres runs under `pg_ctl`, not a unit**, as `pg_dev` does: `crash` and `promote` need the
   postmaster's pid and no supervisor restarting it. Its synchronous settings live in `role.conf`
   outside the data directory, so a base backup never copies them to a standby.
7. **`max_connections` 200** on the battery's Postgres (the store needs 80; the replication and
   `psql` take a few more; headroom for a restart with connections not yet reaped).
8. **The store follows failover by libpq's host list** (`host=pg1,pg2 ...
   target_session_attrs=read-write`); tested locally with a real server across crash and
   promote: ZC-E0213 on the calls in flight, retried, the server stays up.
9. **The units have `Restart=no`**: the harness decides when a killed process comes back. The
   agent's has `KillMode=process`, so stopping it leaves the containers' supervisors running, as
   `zcube-agent` intends.
10. **The admin client certificate is named `jepsen`**; LISTEN and STORE are arguments of
    `zigcube.sh server`, with no defaults.
11. **Test hooks**: `ZCUBE_SYSTEMCTL`, `ZCUBE_ETC`, `ZCUBE_OPT`, `ZCUBE_VAR`, `ZCUBE_UNIT_DIR`
    (and `ZCUBE_PG_DIR`, `ZCUBE_PG_PORT`, `ZCUBE_PG_BIN`) let `ops/jepsen/test-recipe.sh` run the
    scripts in a scratch directory. The scripts refuse to run as anyone but root, so the test
    skips as `tester` and runs only in a root `zig build test`. CI's `check` job runs it under
    `sudo` (allowed on a runner, never on a developer's host).
    `ops/jepsen/test-postgres.sh` runs `postgres.sh` (a primary and a synchronous standby on two
    ports, a crash, a promotion, the old primary refused and rebuilt as a standby) and
    `fault.sh pause postgres`, then `test-recipe.sh` against that pair; CI's `jepsen` job runs it
    under `sudo` on the executables of a `zig build dist` tarball (routed by `ops/jepsen/*`,
    `src/dist.zig` and the client's sources, `.github/ci-changes.sh`).
