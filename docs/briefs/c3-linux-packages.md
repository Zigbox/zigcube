# C3 input: deb and rpm packages

Owner, 2026-11-04: ship Zigcube as Debian packages and RPMs in C3, from the same signed apt and
dnf repository as Zigbox (Zigbox `docs/briefs/linux-packages.md`). This is a list to fold into
C3's brief when it is written, not a brief. It is one or two slices.

## Scope

- **Three packages,** per architecture (`amd64`/`x86_64`, `arm64`/`aarch64`):
  - `zigcube`: the `zcube` command.
  - `zigcube-server`: `zcube-server`, a systemd unit, a `zcube` system user, a default config in
    `/etc/zigcube/server.zon` listening on `127.0.0.1` (its writes are unauthenticated), and state
    under `/var/lib/zigcube`. The unit is installed but not enabled.
  - `zigcube-agent`: `zcube-agent`, a systemd unit, a default config, `Depends: zigbox` (the
    agent runs Zigbox containers). Not enabled on install: it needs `--server` and the node's
    sizes first.
- **Built in Zig, as Zigbox builds its packages,** reusing its deb and rpm writer (a module in the
  pinned `zigbox` package, or a copy if it is not exported). No `dpkg-deb`, `rpm` or `fpm`.
- **One repository** with Zigbox's: the same suites, the same key, published together.
- **CI** builds the packages on every release PR and checks them in the VM. CI never signs or
  publishes.

## Cost and constraints

- **`zcube-server` is not static.** It links SQLite and libpq from the system (`build.zig`,
  `linkSystemLibrary("sqlite3")` and `("pq")`), so its packages are per distribution release:
  `Depends: libsqlite3-0, libpq5` (deb) and `sqlite-libs, libpq` (rpm), built against each
  supported release's glibc. `zcube` and `zcube-agent` should be static and distribution-neutral;
  check that they are.
- Maintainer scripts are the minimum: create the system user, `systemctl daemon-reload`. Upgrades
  restart nothing on their own; the README says when to restart the server and the agents
  (mixed versions are parked, so the release notes say "upgrade the server, then the agents").
- Signing on the owner's machine, with Zigbox's key and tool.

## Unknowns to settle first

1. How `zcube-server` is built for several glibc baselines without libc in the build host's
   sense: in a container or VM per distribution, or by bundling SQLite and libpq statically
   (libpq pulls OpenSSL and more). Default: build per distribution in the VM harness; cut to
   Ubuntu 24.04 and one RHEL 9 compatible if the matrix is costly.
2. Whether Zigbox's package writer is in the pinned module by the time C3 starts. If not, the
   slice waits for it or copies it (and records which).

## Demo

In the Ubuntu VM, from the repository: `apt install zigcube-server zigcube-agent zigcube`, start
both units with a config that names the server, `zcube get nodes` lists the node, `zcube apply`
of a one-replica service runs it, `systemctl restart zcube-agent` adopts it. The same with `dnf`
in the rpm VM. `apt remove` and `dnf remove` stop the units and leave `/var/lib/zigcube`.
