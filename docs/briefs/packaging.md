# Brief: packaging and release automation (B7 release, v0.5.1)

Owner: Zigcube releases match Zigbox's: a signed, notarized macOS build installed through the
`Zigbox/homebrew-tap` tap, signed `.deb` and `.rpm` packages, and apt and dnf repositories served
from zigbox.org. Wanted in 0.5.1; if it is not ready by then it goes in 0.6.0 (cutoff below).

This brief folds in two earlier owner inputs, `c3-linux-packages.md` and `c3-macos-cli.md`
(2026-11-04). Where it departs from them it says so under "Departures", and each departure is a
question for the owner (**ASK**), not a choice.

Read first: `AGENTS.md`, `docs/STYLE.md`, `REVIEW.md`; Zigbox's `docs/releases/automation.md` and
`packaging.md` (the model; this brief does not repeat them); and the decision file
`docs/decisions/2026-11-14-zigcube-packages.md`, which holds the contract.

## What the build makes (measured 2026-11-14, ReleaseSafe, x86_64, Ubuntu 24.04, Zig 0.17.0)

- `zcube` and `zcube-agent`: **static, no libc.** One binary per architecture, distribution
  neutral. They cross-compile from one runner.
- `zcube-server`: **dynamic.** It needs `libsqlite3.so.0`, `libpq.so.5` and glibc (symbols up to
  `GLIBC_2.36` when built here). The other libraries `ldd` lists are libpq's own and come with its
  package. It cannot be cross-built from this runner: `-Dtarget=x86_64-linux-gnu.2.28` fails to
  link (the host's libpq and SQLite want glibc 2.34+ symbols), and any non-native target finds no
  `sqlite3` or `pq` at all (`--search-prefix` helps only with a matching sysroot).
  - Consequence: the server is built **natively, inside a container of the oldest supported
    baseline**, and runs on everything newer. A binary built on a RHEL 9 compatible image (glibc
    2.34, libpq 13, SQLite 3.34) runs on Debian 12, Ubuntu 24.04, Fedora and RHEL 9; the reverse
    does not hold. The store uses nothing newer than SQLite 3.8 (`WITHOUT ROWID`; no `RETURNING`).
    The sonames are the same on all four. aarch64 builds natively on an arm64 runner.
    Slice 1 proves it by installing the one package on all four and starting the server; if a
    distribution refuses it, the fallback is one server build per distribution, which needs apt
    suites per distribution and is then a new question to the owner.
- `zcube` builds for `aarch64-macos` today (checked; not run). `zcube-agent` does not (56
  compile errors: Linux-only code) and `zcube-server` cannot (no SQLite or libpq to link).
  **The Mac release is `zcube` alone**, as `c3-macos-cli.md` says: the agent runs containers, which
  need Linux, and a Mac user talks to a remote server. `zcube local` on macOS must refuse with one
  line saying why (slice 2 checks it does).
- Zigbox's package writer is exported as the `zigbox_package` module, but it is **not enough**:
  a package there has `recommends` only, no `Depends`, no maintainer scripts, no config-file
  marks, and the apt suite is the constant `stable`. Its orchestration (`package_main.zig`,
  `package_check.zig`, `package_release.zig`, `release_assets.zig`, `mac_release.zig`,
  `.github/release-sign.sh`, `package-refresh.sh`) is in Zigbox's `src/` and `.github/`, not in
  the module.

## Decisions to make now (the contract is in the decision file)

1. **Repository layout (ASK).** Recommended: **one site, one key, one keyring, two suites.**
   - apt: the same tree, `https://zigbox.org/apt`, with a second suite `zigcube` beside
     `stable`. One deb822 source names both: `Suites: stable zigcube`. Zigcube's files are
     `apt/dists/zigcube/**` and `apt/pool/main/z/zigcube*/**`; Zigbox's are untouched.
   - dnf: `https://zigbox.org/rpm/zigcube/$basearch/`, beside Zigbox's `rpm/$basearch/`.
   - Each product signs, re-dates and publishes **its own** suite, with the same release key. Nothing
     is re-signed when the other product releases, and neither release workflow reads the other's
     assets.
   - Compared with **one shared suite** (one `Release` listing both products): that file is
     re-signed whenever either product releases, so each release must download the other's
     packages and merge them; Zigbox's `release.yml`, `package-refresh` and package tool must change
     to do the same in reverse; two releases at once race on the file; and the writer's
     `suite = "stable"` constant becomes shared state. It buys nothing the second suite does not
     (one source, one key), and it changes Zigbox's workflows, which is on the Ask-first list.
   - Compared with **separate hosts or keys**: users add two sources and two keys. No.
2. **Signing key.** The same release key (primary `09991DC39816D3C914E2A22C5AB00BC328B7DBB7`, the
   signing subkey as a secret) and the same Developer ID. Zigcube pins the primary's fingerprint
   in `release.yml` and checks in the public key as `docs/releases/zigbox-release-key.asc`, as
   Zigbox does. Users already trust it; a second key would be a second thing to renew every year.
   **ASK**: the secrets are copies in Zigcube's own environments (below). That is a new place for
   an existing key, not a new key.
3. **How the site takes Zigcube's asset.** The release attaches `zigcube-repos.tar.gz`, holding
   only the paths above, no keyring and no dot files. `Zigbox/website` `deploy.yml` gets a second
   fetch step, a copy of the first with its own allow-list, that takes the newest Zigcube release
   with that asset, refuses any path outside `apt/dists/zigcube/`, `apt/pool/main/z/zigcube*/` and
   `rpm/zigcube/`, refuses any path Zigbox's asset also holds, and adds the files to the same
   manifest, so the existing byte-for-byte check after deploying covers both. **ASK**: this changes
   the website's `AGENTS.md` rules ("/apt and /rpm are Zigbox's one asset"). The change is on a
   branch of Zigbox/website; nothing is opened there.
4. **Homebrew (ASK).** Recommended: a **separate formula `zigcube`** in `Zigbox/homebrew-tap`
   (`brew install zigbox/tap/zigcube`), installing `zcube` from the universal zip. Zigcube's
   release writes `Formula/zigcube.rb` only, through the contents API with the blob SHA it read,
   refusing any change but `url`, `version` and `sha256` (Zigbox's `tap-formula` action, copied).
   It never touches `zigbox.rb`.
   - `c3-macos-cli.md` asked for `zcube` to join the `zigbox` formula. That needs one formula
     with two archives from two repositories, updated by two release workflows, so Zigbox's
     `tap-formula` check and its release must change. Not done unless the owner asks.
   - The Mac `zcube` needs no virtualization entitlement (it starts no VM): hardened runtime only.
5. **Package set (set by the owner, 2026-11-14).** Linux only; deb and rpm alike.

   | Package | Holds | Depends |
   |---|---|---|
   | `zigbox` | `zbx`, static | none |
   | `zigcube` | `zcube` only | none |
   | `zigcube-server-sqlite` | `zcube-server` built with the SQLite and memory stores, unit (not enabled) | `zigcube`, `libsqlite3-0` (rpm: `sqlite-libs`) |
   | `zigcube-server-postgres` | `zcube-server` built with the Postgres and memory stores, unit (not enabled) | `zigcube`, `libpq5` (rpm: `libpq`) |
   | `zigcube-agent` | `zcube-agent`, unit (not enabled) | `zigcube`; Recommends `zigbox` |
   | `zigbox-dev` | no files | `zigbox (>= <pinned Zigbox version>)`, `zigcube-server-sqlite`, `zigcube-agent` |

   - The two server packages install the same `/usr/bin/zcube-server`: each `Conflicts` with and
     `Replaces` the other, and both `Provide` `zigcube-server` (you never need both stores).
   - `zigbox-dev` was `zigbox-all` in the first message; renamed. Built in Zigcube's release.
   - Installing starts nothing: both units ship disabled because both need a config file first.
   - **The agent never runs `zbx`** (checked: `src/` has no exec of it; it links Zigbox's module and
     only *names* `zbx doctor` and `zbx pull` in advice to the user), so `Recommends` stays.
   - **macOS:** Homebrew has `zbx` and `zcube` only. The `zigcube` formula `depends_on` the tap's
     `zigbox` formula: on a Mac the server and agent run inside the zbx VM, so `zcube` alone is
     no use there. The Linux `zigcube` package keeps no dependencies.
   - **ASK (collision):** a package named `zigbox` holding `zbx` is also what Zigbox's own release
     publishes in suite `stable`. If Zigcube's release builds one too, two products ship one name
     (and `zigbox-dev`'s `>=` pin points at whichever wins). Proposed: Zigcube does **not** build
     `zigbox`; the name is Zigbox's, from suite `stable`, which the one apt source already carries.
     Say if the owner meant otherwise.
6. **The package writer.** Copy `zigbox_package`'s sources into `src/package/` with a header
   naming the Zigbox commit, and extend the copy (`Depends`, `Conflicts`, maintainer scripts,
   config-file marks, a suite name). Reason: Zigcube pins a released Zigbox tag, so an upstream
   change would reach it only with a Zigbox release, and Zigbox 0.5.1 is in flight. The copy
   drifts; the retro after 0.5.1 decides whether to upstream. The tool, the check, the signing
   script, the release-assets writer and the Mac writer are ported the same way (mechanical, done
   by a Haiku subagent from Zigbox's `main`, diff checked).

## Slices

Cutoff, in the owner's words: ready by the 0.5.1 tag or it goes in 0.6.0. Slices 1 and 2 are
reviewed by about T+4h and slice 3 by T+6h; if slice 3 is not reviewed by T+6h, the supervisor
moves everything to 0.6.0, because the owner's setup and an `rc` dry run still have to follow it.
The release workflow cannot run for real until the owner sets the secrets (below).

0. **Store split (its own slice, own report).** A build option `-Dstore=sqlite|postgres|all`
   (`all` the default for development and CI) compiles in one store plus the memory store and links
   only its library. A `--store` naming a backend not built in is refused with a one-line error;
   that error needs a `ZC-` code, **ASK before registering it**. It changes gated code, so the
   report carries `check: PASS` (store:memory, sqlite) and the Postgres suite (`zig build pg-up`,
   `ZCUBE_TEST_POSTGRES` set). Slice 1 needs it for the two server builds.
1. **Linux packages, signed with a throwaway key.** The writer copy and its extensions; the six
   packages for x86_64 and aarch64; `zig build packages`, `packages-check`, `release-assets`
   (tarballs, SBOM, `SHA256SUMS`) and `release-sign.sh` ported; the server's build in a
   RHEL 9 compatible container, so it is a script or a documented command, not part of
   `zig build`; the apt `zigcube` suite and the dnf tree. Tests: the writer's unit tests, the
   `-Dtest-key` pipeline, and a `packages-test` job that signs with a throwaway RSA 4096 key
   made like the release key, serves the trees over a local file or HTTP source, and in four
   containers (Debian 12, Ubuntu 24.04, Fedora, Rocky 9) installs `zigbox-dev` (and each server flavour in turn), runs `zcube
   --version`, starts `zcube-server --help` and checks `ldd`, `apt remove` or `dnf remove`
   leaving `/var/lib/zigcube`, and a second install from an older package keeping an edited
   `server.zon`. `systemd-analyze verify` on both units. Not tested here: a booted systemd (the
   c3 demo's VM; stays C3).
2. **macOS.** `zig build mac-release` ported: both architectures, `lipo`, hardened runtime, no
   entitlement, notarize, the zip, its `.sha256`, `Formula/zigcube.rb` from a template.
   `mac-check-zip` copied. A `mac-test` job on `macos-15`: a throwaway self-signed identity in a
   temporary keychain, no notarization, `zcube --version`, `zcube --help`, `zcube local` refusing
   in one line, and the unit tests that build on macOS. Zigcube has no macOS job today, so this
   job is new, and `ci-changes.sh` gets a rule and a row in its table test.
3. **The release workflow.** `.github/workflows/release.yml`: `plan`, `mac-check`, `preflight`,
   `draft`, `linux`, `mac`, `prepare`, `publish`, `tap`, `site`, `verify`, and the `test`,
   `mac-test`, `draft-test` jobs; `package-refresh.yml` for the `zigcube` suite; the actions
   (`setup-gh`, `find-draft`, `tap-formula`, `mac-check-zip`, `setup-zig-macos`), pinned as
   Zigbox's are. The version comes from `build.zig.zon` (now `0.0.0`; the release PR sets
   `0.5.1`), the notes from `docs/releases/<v>.md`. `verify` installs `zigbox-dev` from zigbox.org on
   Ubuntu and brews `zigcube` on a Mac, so it needs Zigbox's repository to carry `zigbox`:
   **Zigbox 0.5.1 is published first.** Triggers are pull requests that touch the release files
   (never a plain branch push, AGENTS.md) and `workflow_dispatch`.
4. **Website branch and runbook.** The `deploy.yml` and `AGENTS.md` change on a branch of
   `Zigbox/website`, reported, no PR; `docs/releases/automation.md` and `packaging.md` for Zigcube
   (the owner's runbook with every secret and variable, the environment of each, and the commands,
   as Zigbox's has them). This slice can run beside slice 1 once the owner answers question 1.

## Non-goals

- No VM demo (`demo-c3` stays C3's), no `zcube-server` or `zcube-agent` on macOS, no Windows.
- No change to Zigbox's `release.yml`, `package-refresh.yml`, formula or package tool.
- No distribution archive keyring package (Zigbox's follow-up).
- No new key, no new GitHub App, no new App permission.
- Nothing is published, tagged or pushed to Zigbox's `main`, the tap's `main` or the website's
  `main` by this work. The `v0.5.1-rc.1` dry run is the supervisor's, after the owner's setup.

## How it is tested, and what cannot be

Throwaway keys only: a throwaway RSA 4096 primary with one signing subkey for the packages and
for `SHA256SUMS`; a throwaway self-signed code identity for macOS. The `test`, `mac-test` and
`draft-test` jobs run them on pull requests. What no test here can show, and the `rc` dry run
must: the real key and its pinned fingerprint, the Developer ID and notarization, the App token,
the tap write, the site dispatch and the deploy, `brew install` of a notarized zip, and apt and dnf
against zigbox.org. A report says plainly which of these ran.

## Owner's secrets (set by the owner; nothing goes through a session)

All in `Zigbox/zigcube`, the same values as Zigbox's, set with `gh` from a file or a prompt.

| Environment | Secrets and variables |
|---|---|
| `release` (owner approval, `main` only) | `ZIGBOX_SIGNING_KEY`, `ZIGBOX_SIGNING_PASSPHRASE`, `MAC_CERT_P12`, `MAC_CERT_PASSWORD`, `MAC_NOTARY_KEY`; variables `MAC_NOTARY_KEY_ID`, `MAC_NOTARY_ISSUER_ID` |
| `release-publish` (`main` only, no reviewer) | `RELEASE_APP_PRIVATE_KEY`; variable `RELEASE_APP_ID` |
| `package-refresh` (`main` only, no reviewer) | `ZIGBOX_SIGNING_KEY`, `ZIGBOX_SIGNING_PASSPHRASE`, `RELEASE_APP_PRIVATE_KEY`; variable `RELEASE_APP_ID` |

The App "Zigbox Release" is already installed on the tap and the site repository and not on a
product repository; Zigcube's jobs mint tokens for those two and need nothing more. The subkey
renewal (yearly) now sets the secret in two repositories' environments; the runbook says so.

## Departures from Zigbox's design and from the c3 inputs

- A second suite and a subdirectory in the shared trees, instead of one asset that is the whole
  tree (the site merges two assets).
- A copied package writer with additions, not the exported module alone.
- The server is built in a container, because it is dynamic.
- The package set is the owner's (six packages, two server flavours); see item 5.
- A separate Homebrew formula.
- No `release-test/**` push trigger (AGENTS.md: CI runs on pull requests and `main`).
