# Packaging a Zigcube release

The runbook for Zigcube's Linux packages and their repositories on zigbox.org: what is built, how
it is signed and published, what the owner sets up once and renews every year. The release
workflow itself, its jobs, every secret and variable and the setup guide are in
[automation.md](automation.md). The contract (layout, key, site, tap, package set) is
[the decision](../decisions/2026-11-14-zigcube-packages.md); the plan is
[the brief](../briefs/packaging.md). Zigbox's `docs/releases/packaging.md` and `automation.md` are
the model, and where this file says "as Zigbox does" it means them.

`zig build packages` writes the Zigcube `.deb`s and `.rpm`s (`zigcube`, `zigcube-server-sqlite`,
`zigcube-server-postgres`, `zigcube-agent`, `zigbox-dev`) for x86_64 and aarch64, and the apt suite
`zigcube` and the rpm repositories `rpm/zigcube/<arch>` around them, under `zig-out/packages/`. It
never runs `gpg` and never holds the release key; signing is the release workflow's job, with the
signing subkey as a secret of a GitHub environment. The output is reproducible (the same inputs give
the same bytes).

**Status (2026-11-14).** Slice 1 (packages, signing script, install test, release assets) is built
and reviewed. The release workflow (`release.yml`, `package-refresh.yml`) is slice 3 and not
written yet: every job and file name below that belongs to it is the one the brief lists, and
anything that depends on how slice 3 builds it is marked *per slice 3*. The website change is
slice 4 and waits on the owner (see "The site deploy"). Nothing is published yet.

## What users get

One site, one key, two suites. Zigbox publishes suite `stable` (the `zigbox` package, `zbx`) and
Zigcube publishes suite `zigcube` in the same apt tree; the rpm trees sit side by side. A user adds
one keyring and one source:

```sh
curl -fsSL https://zigbox.org/zigbox-archive-keyring.gpg | sudo tee /usr/share/keyrings/zigbox.gpg >/dev/null
sudo tee /etc/apt/sources.list.d/zigbox.sources >/dev/null <<'EOF'
Types: deb
URIs: https://zigbox.org/apt
Suites: stable zigcube
Components: main
Signed-By: /usr/share/keyrings/zigbox.gpg
EOF
sudo apt update && sudo apt install zigbox-dev
```

A user who already has Zigbox's one-line `zigbox.list` either adds `zigcube` to a deb822 file as
above (and deletes the `.list`) or adds a second line,
`deb [signed-by=/usr/share/keyrings/zigbox.gpg] https://zigbox.org/apt zigcube main`.

For dnf, `/etc/yum.repos.d/zigcube.repo` beside Zigbox's `zigbox.repo` (the same key):

```ini
[zigcube]
name=Zigcube
baseurl=https://zigbox.org/rpm/zigcube/$basearch
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://zigbox.org/zigbox-archive-keyring.asc
```

`zigbox-dev` depends on `zigbox` from the other suite or repository, so both must be configured.
The packages:

| Package | Holds | Depends |
|---|---|---|
| `zigcube` | `zcube` (static) | none |
| `zigcube-server-sqlite` | `zcube-server` with the SQLite and memory stores; `zcube-server.service`, disabled; `/etc/zigcube/server.zon` | `zigcube`, `libsqlite3-0` (rpm: `sqlite-libs`) |
| `zigcube-server-postgres` | `zcube-server` with the Postgres and memory stores; the same unit and file | `zigcube`, `libpq5` (rpm: `libpq`) |
| `zigcube-agent` | `zcube-agent` (static); `zcube-agent.service`, disabled; `/etc/zigcube/agent.zon` | `zigcube`; Recommends `zigbox` |
| `zigbox-dev` | nothing | `zigbox (>= <pinned Zigbox version>)`, `zigcube-server-sqlite`, `zigcube-agent` |

The two server flavours install the same `/usr/bin/zcube-server`: on deb each `Conflicts` with and
`Replaces` the other, on rpm each `Conflicts` with the other, and both provide `zigcube-server`.
Installing starts nothing. Zigcube never builds a package named `zigbox`: that name is Zigbox's,
from suite `stable`.

Once Zigcube's first release is live, the user-facing copy of these commands belongs in the README
and the project site, the same way Zigbox's README carries its own.

## The owner's part

A release is automated ([automation.md](automation.md)). The owner sets up the environments, the
secrets and the variables once (its "Setup guide"), applies the website change once (below), and
renews the signing subkey every year in **both** repositories (below). For each release:

- **Zigbox's release is published first.** Zigcube's `verify` installs `zigbox-dev` from
  zigbox.org, which needs `zigbox (>= the pinned version)` in suite `stable`.
- The supervisor merges Zigcube's release PR (version in `build.zig.zon`, notes in
  `docs/releases/<v>.md`, the gates AGENTS.md "Releases" asks for, quoted).
- `release.yml` checks what can refuse, makes a draft release, and waits for the owner's one
  approval of the `release` environment. Before approving, open the run and check that its commit is
  the release commit on `main`: an approval hands the key to whatever that commit holds.
- After the approval the workflow signs, attaches, publishes (which makes the tag), writes the tap
  formula, dispatches the site deploy and installs from the public places. The owner does nothing
  more unless a job fails.

## Building the executables

`.github/build-release-bin.sh` builds the four executables the packages carry, for the machine's
own architecture, into `zig-out/release-bin`:

- `zcube-<arch>` and `zcube-agent-<arch>`: static, built on the host.
- `zcube-server-sqlite-<arch>` and `zcube-server-postgres-<arch>`: dynamic (glibc, libsqlite3 or
  libpq), built with `-Dstore=sqlite|postgres` in a digest-pinned Rocky Linux 9 container. That is
  the RHEL 9 build: glibc 2.34 at most, so one binary runs on Debian 12, Ubuntu 24.04, Fedora and
  RHEL 9. The install test checks the bound with `objdump -T`.

A release needs both architectures; aarch64 is built the same way on an arm64 runner (*per slice
3*: how `linux` gathers the two architectures' executables into one signing run). The script needs
zig on PATH, docker, and `zig-pkg/` holding the pinned Zigbox package.

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
  public parts land at the tree's root as `zigbox-test-key.gpg` and `.asc`. Never publish a tree
  made this way (the site refuses one).

The `Release` says `Origin: Zigbox`, `Suite: zigcube`, `Codename: zigcube`. The deb pool is
`apt/pool/main/z/<package>/`: `zigcube*` for four packages and `zigbox-dev` for the fifth.

## The release key

The same key as Zigbox's. Users already trust it, and a second key would be a second thing to renew
every year. Its primary (RSA 4096, certify only, offline) has the fingerprint

```
09991DC39816D3C914E2A22C5AB00BC328B7DBB7
```

and its public key is checked in as [`zigbox-release-key.asc`](zigbox-release-key.asc), a copy of
Zigbox's file of the same name. Every signature check in Zigcube's scripts is against that file and
that fingerprint, never against a keyring inside an asset. The fingerprint is pinned in reviewed
code: `ZIGBOX_SIGNING_FPR` is set in `release.yml` and `package-refresh.yml` (*per slice 3*), not
as a variable or secret. The keyring users fetch stays `https://zigbox.org/zigbox-archive-keyring.gpg`,
which Zigbox's asset carries; Zigcube's asset carries none.

Zigcube's environments hold **copies** of the signing subkey export and its passphrase (the
secrets `ZIGBOX_SIGNING_KEY` and `ZIGBOX_SIGNING_PASSPHRASE`, in `release` and `package-refresh`;
[automation.md](automation.md) has the commands). That is a new place for an existing key, not a new
key. How the key was made, its offline backup and its revocation certificate are in Zigbox's
`packaging.md`, "One-off key setup"; none of it is repeated for Zigcube.

When Zigbox's file changes (a renewal or a revocation), copy it here in the same week:

```sh
cp ../zigbox/docs/releases/zigbox-release-key.asc docs/releases/zigbox-release-key.asc
gpg --show-keys --with-subkey-fingerprints docs/releases/zigbox-release-key.asc
```

and check that the primary fingerprint is the one above and the new subkey's expiry is shown.

### Yearly renewal: four environments now

The signing subkey expires after a year. Renewal follows Zigbox's `packaging.md`, "Yearly renewal",
with one addition: the new export goes into **four** environments, two in each repository. On the
machine that holds the primary key, with `$KEY` the primary's fingerprint and `$SUBKEY` the
(renewed or new) signing subkey's:

```sh
gpg --quick-set-expire "$KEY" 1y "$SUBKEY"     # or add a new subkey, as in Zigbox's runbook
for repo in Zigbox/zigbox Zigbox/zigcube; do
  for env in release package-refresh; do
    gpg --armor --export-secret-subkeys "$SUBKEY"'!' |
      gh secret set ZIGBOX_SIGNING_KEY --env "$env" --repo "$repo"
  done
done
```

If the passphrase changed, set `ZIGBOX_SIGNING_PASSPHRASE` the same way (`gh` prompts for it; run
`gh secret set ZIGBOX_SIGNING_PASSPHRASE --env "$env" --repo "$repo"` once per pair). Then:

1. Commit the new public key to Zigbox (`gpg --armor --export "$KEY"`) and copy it to Zigcube, as
   above, each in a reviewed PR.
2. Dispatch Zigcube's `package-refresh` (`gh workflow run package-refresh.yml --repo Zigbox/zigcube`)
   and check it passes: it is the first use of the new secret in Zigcube.
3. The "re-fetch the keyring" notice of Zigbox's runbook covers Zigcube's users too, since it is one
   keyring; Zigcube's next release notes carry the same line.

Renew at least 28 days before the expiry: both products' signing scripts and refreshes refuse a key
that lapses within 28 days of the signing time. A renewal done in Zigbox's environments alone makes
Zigcube's weekly refresh fail at the key check, loudly, 28 days before the old expiry, which is the
alarm that the Zigcube copies were forgotten.

If the subkey leaks, revoke it with the primary key, set a new one in all four environments and
copy the public key to both repositories.

## Signing

`.github/release-sign.sh OUTPUT_DIR` signs in two rounds with the signing subkey, as Zigbox's does.
The subkey arrives in `ZIGBOX_SIGNING_KEY` and its passphrase in `ZIGBOX_SIGNING_PASSPHRASE`; both
go through files and file descriptors in a throwaway `GNUPGHOME`, never argv or the log. Its other
inputs are `ZIGBOX_SIGNING_FPR` (the pinned primary), `ZCUBE_BIN_DIR` (the executables),
`ZCUBE_ZIGBOX_VERSION` (`zigbox-dev`'s lower bound), `ZIGBOX_SIGNED_AT` (Unix seconds; default
now; anything but digits is refused) and `ZCUBE_PUBLIC_KEY` (default
`docs/releases/zigbox-release-key.asc`). In order:

1. Imports the key; checks the primary is `ZIGBOX_SIGNING_FPR`, both are RSA 4096, and neither
   expires within 28 days of the signing time (`Valid-Until` is 21 days out; the 7 after are the
   owner's margin to renew). A refusal names the key to renew.
2. Round 1: `zig build packages` writes unsigned rpms and their headers under `to-sign/`; each
   header gets a detached signature.
3. Round 2: `zig build packages -Dsignatures=DIR` embeds them; `InRelease`, `Release.gpg` and each
   `repomd.xml.asc` are signed; a last build places them and `packages-check` reads the tree back.
4. Verifies everything against the checked-in public key alone (`gpg --verify`, `rpm -Kv`): every
   signature must be by a subkey of the pinned primary, not by the primary.
5. Writes `OUTPUT_DIR/zigcube-repos.tar.gz`: `apt/` and `rpm/` holding only
   `apt/dists/zigcube/`, `apt/pool/main/z/zigcube*/`, `apt/pool/main/z/zigbox-dev/` and
   `rpm/zigcube/`, and refuses to finish if the archive holds any other path.

Signing `SHA256SUMS` into `SHA256SUMS.asc` after the release assets are written, as Zigbox's step 8
does, is *per slice 3* (the script stops at the archive today).

`.github/release-sign-test-container.sh` runs the real path (`release-sign-test.sh`, with a
throwaway RSA 4096 key made like the release key) in a Fedora container, including the refusals
above.

## Release assets

`zig build release-assets -Dno-packages|-Dpackages-dir=DIR [-Dpackage-arch=...]
[-Drepos-archive=FILE]` writes, under `zig-out/release-assets`:

- `zigcube-<v>-linux-x86_64.tar.gz` and `zigcube-<v>-linux-aarch64.tar.gz`: the four executables,
  `LICENSE` and a short README;
- `zigcube-<v>.cdx.json`: a CycloneDX 1.5 SBOM;
- with `-Dpackages-dir`, the debs and rpms; with `-Drepos-archive`, `zigcube-repos.tar.gz`;
- `SHA256SUMS` over everything it holds, to be signed after the last asset is in.

The Mac job adds `zcube-<v>-macos-universal.zip`, its `.sha256`, `SHA256SUMS.macos` and
`zigcube.rb` (slice 2 and *per slice 3*). The exact list the draft must hold is checked by
`prepare` (*per slice 3*).

## The site deploy

zigbox.org is built by `.github/workflows/deploy.yml` in `Zigbox/website`. Today it copies Zigbox's
`zigbox-repos.tar.gz` and nothing else under `/apt` and `/rpm`. Slice 4 adds a second fetch step
that takes the newest Zigcube release (not a draft, not a prerelease) carrying
`zigcube-repos.tar.gz` and:

- refuses an asset holding anything but files and directories, any file outside
  `apt/dists/zigcube/`, `apt/pool/main/z/zigcube*/`, `apt/pool/main/z/zigbox-dev/` and
  `rpm/zigcube/` (the directories above them are allowed as directories), a keyring, a dot file,
  an `.html` file, the test key or `to-sign/`;
- refuses any path Zigbox's asset also holds, and the assembly refuses again any Zigcube file that
  `src/` or Zigbox's tree already put in the site;
- requires `apt/dists/zigcube/{Release,InRelease,Release.gpg}` and both architectures'
  `repomd.xml` and `repomd.xml.asc`, and no file over 25 MiB;
- deploys Zigcube's suite only when Zigbox's is deployed (Zigbox's asset carries the keyring);
- adds its files to the same manifest, so the check after deploying fetches every file of both
  assets from zigbox.org and fails unless each is served with status 200 and the asset's bytes.

Zigbox's step, its refusals and its required files are unchanged. The check is
`.github/check-zigcube-asset.sh` in the website repository, and
`.github/check-zigcube-asset-test.sh` is its table test (one accepted asset, one with `./`
prefixes, and a refusal for each rule above). The website's `AGENTS.md` changes with it: `/apt` and
`/rpm` hold one asset per product.

**The change is a patch, not a branch.** The implementer session could not attach
`Zigbox/website` with write access, so it is
[`website-zigcube-suite.patch`](website-zigcube-suite.patch) here (one commit, `git format-patch`
of `Zigbox/website` `2a2875a`). The owner, or a session given write access, applies it, once,
before Zigcube's first release:

```sh
git clone https://github.com/Zigbox/website && cd website
git switch -c claude/b7-zigcube-packages
git am /path/to/zigcube/docs/releases/website-zigcube-suite.patch
bash .github/check-zigcube-asset-test.sh        # ends in "check-zigcube-asset-test: PASS"
git push -u origin claude/b7-zigcube-packages
```

then opens a pull request there and merges it (the deploy's pull request run assembles the site
with both assets and deploys nothing). Until it is merged the deploy ignores Zigcube's asset, and
Zigcube's `site` job, which waits for the deploy and then checks that zigbox.org serves the
`zigcube` suite, fails after `publish` (*per slice 3*).

The release's `site` job sends the website a `repository_dispatch` of type `site` with a token of
the App "Zigbox Release" and waits for the run it started (*per slice 3*). The deploy also runs
every six hours by itself and on every push to its `main`, so a Zigbox release redeploys Zigcube's
files unchanged, and the other way round.

## Keeping apt fresh

The `zigcube` suite's `Valid-Until` is 21 days after signing, like `stable`'s, and Zigcube re-dates
only its own suite: `.github/workflows/package-refresh.yml` runs weekly and on dispatch in the
environment `package-refresh` (*per slice 3*: the schedule, the script name, the artifact name). It
follows Zigbox's refresh: it takes the newest Zigcube release's `zigcube-repos.tar.gz`, `SHA256SUMS`
and `SHA256SUMS.asc` and the `InRelease` zigbox.org serves for `zigcube`, refuses unless every old
signature is by the pinned subkey and the archive is the one the signed `SHA256SUMS` names, re-dates
with `zig build packages-redate`, signs `InRelease`, `Release.gpg` and the new `SHA256SUMS`, uploads
them to the release with `--clobber`, dispatches the site deploy and checks the served `InRelease`
is valid for at least ten more days.

The two refreshes never touch each other's files, so they may run at the same time; pick a
schedule that does not coincide with Zigbox's (Monday 05:17 UTC) anyway, so a failure is easy to
place.

GitHub disables a scheduled workflow after 60 days without repository activity, silently. Check
Zigcube's Actions tab at least every 50 days, as for Zigbox's, and re-enable `package-refresh` if
it was disabled: no run means no alarm, and apt refuses the `zigcube` suite 21 days after the last
signing.

Recovery from a half-finished upload is Zigbox's procedure with Zigcube's names (*per slice 3*:
the artifact's name):

```sh
gh run download RUN_ID --repo Zigbox/zigcube -n package-refresh-vX.Y.Z --dir saved
gh release upload vX.Y.Z saved/zigcube-repos.tar.gz saved/SHA256SUMS saved/SHA256SUMS.asc \
  --clobber --repo Zigbox/zigcube
gh workflow run package-refresh.yml --repo Zigbox/zigcube
```

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

What no test before the first release can show, and the `v0.5.1-rc.1` dry run must: the real key
and its pinned fingerprint in Zigcube's environments, the App token, the site dispatch and the
deploy with both assets, and apt and dnf against zigbox.org's `zigcube` suite.

## The server's configuration

Both server flavours ship `/etc/zigcube/server.zon` as a configuration file (a dpkg conffile, an
rpm `%config(noreplace)`), and each flavour's file differs: the SQLite one names a database under
`/var/lib/zigcube`, the Postgres one `.store = "postgres:"`
([decision](../decisions/2026-11-14-server-flavour-swap.md)).

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

## Doing it by hand

The fallback when the automation is down, and only with the owner's written go-ahead in
`docs/decisions/`. With the subkey in a throwaway `GNUPGHOME` on a trusted machine, on a checkout
of the release commit with both architectures' executables in one directory:

```sh
export ZIGBOX_SIGNING_FPR=09991DC39816D3C914E2A22C5AB00BC328B7DBB7
export ZCUBE_BIN_DIR=zig-out/release-bin ZCUBE_ZIGBOX_VERSION=<pinned Zigbox version>
export ZIGBOX_SIGNED_AT=$(date +%s)
ZIGBOX_SIGNING_KEY=$(cat subkey.asc) ZIGBOX_SIGNING_PASSPHRASE=$(cat passphrase) \
  .github/release-sign.sh out
zig build release-assets -Dpackages-dir=zig-out/packages -Drepos-archive=out/zigcube-repos.tar.gz
```

(`subkey.asc` and `passphrase` are mode-600 files outside the checkout, deleted afterwards.) Then
sign `zig-out/release-assets/SHA256SUMS` into `SHA256SUMS.asc` with the subkey, attach the assets
to the release, and start the deploy with `gh workflow run deploy.yml --repo Zigbox/website`. The
tag is made by publishing the draft in `release.yml`, never by hand, except under that written
go-ahead.
