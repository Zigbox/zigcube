# C3 input: deb and rpm packages

Owner, 2026-11-04: ship Zigcube as Debian packages and RPMs in C3, from the same signed apt and
dnf repository as Zigbox (Zigbox `docs/briefs/linux-packages.md`, an M8 input). This is a list to
fold into C3's brief when it is written, not a brief. It is one or two slices.

## Packages (owner, 2026-11-04)

A dev wants one install that does everything; an operator installs one role per host. Each
package may carry the `zbx` command where it helps.

| Package | Holds | For |
|---|---|---|
| `zigbox` | `zbx`, `zcube`, `zcube-server`, `zcube-agent`; both units, not enabled | a dev box (`zcube local up`) |
| `zigcube-cli` | `zcube` | an operator's machine, CI |
| `zigcube-server` | `zcube-server`, unit, `zcube` system user, `/etc/zigcube/server.zon`, `/var/lib/zigcube` | the control plane |
| `zigcube-agent` | `zcube-agent`, `zbx`, unit, default config | a worker node |

- **The agent never runs `zbx`**: it links the `zigbox` module (`src/zigbox_runtime.zig`). `zbx`
  is in `zigcube-agent` for `zbx doctor` (is this host set up?) and for debugging a node
  (`zbx ps`, logs, `exec`). `zigcube-agent` depends on `uidmap` and `passt` (deb) or
  `shadow-utils` and `passt` (rpm), which Zigbox needs from the host.
- `zigbox` is Zigbox's M8 package widened: M8 ships it with `zbx` alone, C3 adds Zigcube's three
  executables. It conflicts with the three `zigcube-*` packages (they hold the same files).
- The server's default config listens on `127.0.0.1` (its writes are unauthenticated). No unit is
  enabled on install: the agent needs `--server` and the node's sizes first.
- **Built in Zig, with Zigbox's package writer** (a module in the pinned `zigbox` package, or a
  copy if it is not exported). No `dpkg-deb`, `rpm` or `fpm`. One repository with Zigbox's: the
  same suites, the same key.
- Since all packages but `zigbox`'s M8 form carry Zigcube, they are built by Zigcube's release,
  with `zbx` from the pinned Zigbox.
- **CI** builds the packages on every release PR and checks them in the VM. CI never signs or
  publishes.

## Cost and constraints

- **`zcube-server` is not static.** It links SQLite and libpq from the system (`build.zig`,
  `linkSystemLibrary("sqlite3")` and `("pq")`), so `zigcube-server` and `zigbox` are per
  distribution release: `Depends: libsqlite3-0, libpq5` (deb), `sqlite-libs, libpq` (rpm), built
  against each supported release's glibc. `zigcube-cli` and `zigcube-agent` should be static and
  distribution-neutral; check that they are.
- Maintainer scripts are the minimum: create the system user, `systemctl daemon-reload`. Upgrades
  restart nothing on their own; the release notes say "upgrade the server, then the agents"
  (mixed versions are parked).
- Signing on the owner's machine, with Zigbox's key and tool.

## Unknowns to settle first

1. How `zcube-server` is built for several glibc baselines: per distribution in the VM harness, or
   by linking SQLite and libpq statically (libpq pulls OpenSSL and more). Default: per
   distribution; cut to Ubuntu 24.04 and one RHEL 9 compatible if the matrix is costly.
2. Whether Zigbox's package writer is in the pinned module when C3 starts. If not, the slice
   waits for it or copies it, and records which.
3. How the `zigbox` package's version reads once it carries both projects (Zigbox's version,
   Zigcube's, or both). Decide before the first C3 release.

## Demo

In the Ubuntu VM, from the repository: on one guest `apt install zigcube-server`, on a second
`apt install zigcube-agent`, `zbx doctor` passes there, both units start with a config naming the
server, `zigcube-cli`'s `zcube get nodes` lists the node, `zcube apply` of a one-replica service
runs it, `systemctl restart zcube-agent` adopts it. `apt install zigbox` on a third guest and
`zcube local up` works. The same with `dnf` in the rpm VM. `apt remove` and `dnf remove` stop the
units and leave `/var/lib/zigcube`.
