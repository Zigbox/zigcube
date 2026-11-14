# Packaging a Zigcube release

A stub for slice 1 of `docs/briefs/packaging.md`: what exists and how it is run. The full release
runbook (the workflow, the refresh, the website deploy, the tap) is slice 4. The contract is
`docs/decisions/2026-11-14-zigcube-packages.md`.

`zig build packages` writes the Zigcube `.deb`s and `.rpm`s (`zigcube`, `zigcube-server-sqlite`,
`zigcube-server-postgres`, `zigcube-agent`, `zigbox-dev`) for x86_64 and aarch64, and the apt suite
`zigcube` and the rpm repositories `rpm/zigcube/<arch>` around them, under `zig-out/packages/`. It
never runs `gpg`; the output is reproducible (the same inputs give the same bytes).

## Building the executables

`.github/build-release-bin.sh` builds the four executables the packages carry, for the machine's
own architecture, into `zig-out/release-bin`:

- `zcube-<arch>` and `zcube-agent-<arch>`: static, built on the host.
- `zcube-server-sqlite-<arch>` and `zcube-server-postgres-<arch>`: dynamic (glibc, libsqlite3 or
  libpq), built with `-Dstore=sqlite|postgres` in a digest-pinned Rocky Linux 9 container. That is
  the RHEL 9 build: glibc 2.34 at most, so one binary runs on Debian 12, Ubuntu 24.04, Fedora and
  RHEL 9. The install test checks the bound with `objdump -T`.

A release needs both architectures; aarch64 is built the same way on an arm64 runner. It needs zig
on PATH, docker, and `zig-pkg/` holding the pinned Zigbox package.

## The packages

- `zig build packages [-Dbin=DIR]` reads `zig-out/release-bin` (or `DIR`). `-Dpackage-arch=x86_64`
  (or `aarch64`) builds one architecture: for CI, which builds one; a release has both.
- `-Dzigbox-version` defaults to the Zigbox tag `build.zig.zon` pins: `zigbox-dev` depends on
  `zigbox (>= that version)`.
- `-Dsigned-at=<unix seconds>` sets the apt `Release`'s `Date` and a `Valid-Until` 21 days later,
  and the rpm `repomd.xml` revision and timestamps. Without it the date is fixed (1980) and there is
  no `Valid-Until`: a development tree, never one to publish. `release-sign.sh` passes the same
  value to every build it runs.
- `zig build packages-redate -Dsigned-at=N [-Dpackages-dir=DIR]` rewrites only `Release`'s `Date`
  and `Valid-Until` in an existing tree and deletes the `InRelease` and `Release.gpg` that no longer
  match; it is what a refresh re-signs.
- `zig build packages-check` writes the tree and reads it all back: every file is listed, signed
  and in place, there is no stray file, and a signed tree carries a `Valid-Until` of `Date` + 21
  days.
- `-Dtest-key=true` signs with the tool's fixed Ed25519 test key, which vouches for nothing; its
  public parts land at the tree's root as `zigbox-test-key.gpg` and `.asc`.

## Signing

`.github/release-sign.sh` signs in two rounds with the owner's signing subkey, as Zigbox's does.
The subkey arrives in `ZIGBOX_SIGNING_KEY` and its passphrase in `ZIGBOX_SIGNING_PASSPHRASE`; both
go through files and file descriptors, never argv or the log. The signing time is
`ZIGBOX_SIGNED_AT` (Unix seconds; default now); anything but digits is refused.

The script refuses a key whose primary or signing subkey has expired or expires within 28 days of
the signing time: `Valid-Until` is 21 days out, and the 7 days after that are the owner's margin to
renew. A refused run names which key to renew.

`.github/release-sign-test-container.sh` runs the real path (`release-sign-test.sh`, a throwaway
gpg key it generates) in a Fedora container, including the refusals above.

## Release assets

`zig build release-assets -Dno-packages|-Dpackages-dir=DIR [-Dpackage-arch=...]
[-Drepos-archive=FILE]` writes, under `zig-out/release-assets`, the tarballs of the executables, a
CycloneDX SBOM and `SHA256SUMS` over everything it holds. `SHA256SUMS` is signed after the last
asset is in.

## The install test

`.github/packages-install.sh [IMAGE...]` (CI's `packages` job) builds a 0.0.0 and a 0.0.1 tree
with the test key and a signing time of now (0.0.1's `server.zon` files are edited), serves them
over HTTP on 127.0.0.1, and in Debian 12, Ubuntu 24.04, Fedora 42 and Rocky Linux 9 containers:

- adds the suite with `signed-by` (apt) or `gpgcheck=1` and `repo_gpgcheck=1` (dnf) and the test
  key, and Zigbox's suite from zigbox.org with its real keyring;
- installs `zigbox-dev` by name, with the real `zigbox` from zigbox.org (no stub), and checks the
  versions with `dpkg-query` or `rpm -q`, `ldd`, that no unit is enabled, and that no package
  creates or owns `/var/lib/zigcube`;
- starts the SQLite server and asks it `GET /v1/status`;
- edits `/etc/zigcube/server.zon`, upgrades to 0.0.1 and checks the edit is kept and the new file
  lands as `server.zon.dpkg-dist` or `server.zon.rpmnew`;
- swaps to the Postgres flavour, checks `--store sqlite:` is refused with ZC-E0217, and runs
  `systemd-analyze verify` on both units;
- removes everything.

It needs docker and zigbox.org. `PACKAGES_INSTALL_CA` names a CA bundle for an intercepting proxy.

## The server's configuration

Both server flavours ship `/etc/zigcube/server.zon` as a configuration file (a dpkg conffile, an
rpm `%config(noreplace)`), and each flavour's file differs: the SQLite one names a database under
`/var/lib/zigcube`, the Postgres one `.store = "postgres:"`.

- **`postgres:` is a placeholder.** A fresh Postgres server refuses to start with ZC-E0106
  ("postgres: needs connection settings") until `.store` holds libpq settings, for example
  `"postgres:host=/run/postgresql dbname=zigcube"`. Write them before enabling the unit.
- **A store the build lacks is refused with ZC-E0217.** The SQLite flavour refuses `postgres:` and
  the Postgres flavour refuses `sqlite:`, in one line naming the other package.
- **Swapping flavours** (`apt install zigcube-server-postgres` over the SQLite one, or
  `dnf swap --allowerasing zigcube-server-sqlite zigcube-server-postgres`) keeps the
  administrator's `server.zon`: in the install test, on all four distributions, a file edited
  before the swap still said `.store = "sqlite:/var/lib/zigcube/server.db"` after it, so the
  Postgres server refuses to start (ZC-E0217) until `.store` is rewritten. Check `.store` after
  every swap. The swap also removes `zigbox-dev`, which depends on the SQLite flavour; dnf would
  remove the agent with it unless given `--setopt=clean_requirements_on_remove=False`.
