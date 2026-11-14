# Release automation: spec, bill of materials, setup

Status: spec, 2026-11-14 (slice 4 of [the packaging brief](../briefs/packaging.md)). The workflow
it describes, `.github/workflows/release.yml` and `package-refresh.yml`, is slice 3 and **not
written yet**. Job names, environments, secrets and variables are the brief's and are fixed here;
what depends on how slice 3 writes the jobs is marked *per slice 3*, and slice 3 updates this file
where it differs. The model is Zigbox's `docs/releases/automation.md`: same shape, same App, same
key, same rules. [packaging.md](packaging.md) is the runbook for the packages, the key and the
site; the contract is [the decision](../decisions/2026-11-14-zigcube-packages.md).

## Goal

As in Zigbox: the owner's only act in a release is one approval of the `release` environment.
Everything before it (checks, a draft release) and after it (the signed `zigcube` apt suite and dnf
trees, the notarized Mac zip of `zcube`, the public release and its tag, the tap formula
`zigcube.rb`, zigbox.org, an install from the public places) runs without anyone. The gates do not
change: a release PR still carries what AGENTS.md "Releases" asks for (the fleet's tracker line,
both review verdicts, `check: PASS`), and the supervisor merges it.

Two rules shape the flow, Zigbox's both: **draft first, publish last** (a failure before `publish`
leaves a draft and nothing public), and **no release job runs on a person's machine** (signing and
notarization run on GitHub-hosted runners).

## What differs from Zigbox's release

- **Zigbox's release is published first.** `verify` installs `zigbox-dev` from zigbox.org, which
  depends on `zigbox (>= the pinned version)` from suite `stable`. A Zigcube release that pins a
  Zigbox version not yet on zigbox.org fails `verify` after `publish`; `plan` should refuse it
  before anything is written (*per slice 3*).
- **The Mac build is `zcube` alone**, with the hardened runtime and **no entitlement** (it starts no
  VM). The zip is `zcube-<v>-macos-universal.zip`; the formula is `Formula/zigcube.rb` in
  `Zigbox/homebrew-tap`, which `depends_on "zigbox/tap/zigbox"`. Zigcube's release writes that file
  and never `zigbox.rb`.
- **The site takes a second asset.** `zigcube-repos.tar.gz` holds only Zigcube's suite and rpm tree;
  zigbox.org's deploy merges it beside Zigbox's (packaging.md, "The site deploy"). That change is a
  patch the owner applies once.
- **No `release-test/**` push trigger.** CI runs only on pull requests and `main` (AGENTS.md), so
  `test`, `mac-test` and `draft-test` run on pull requests that touch the release files, and
  `release` by `workflow_dispatch` too.
- **The servers are built in a container** (Rocky Linux 9, digest-pinned) because they link glibc,
  SQLite and libpq; `zcube` and `zcube-agent` are static.

## The flow

One workflow, `release.yml`, one run, a `needs:` chain (job names from the brief; the steps inside
them *per slice 3*).

```
release PR merged to main (supervisor; version in build.zig.zon, notes in docs/releases/<v>.md)
  └─ ci green on that main commit  ──►  release.yml (workflow_run), or by hand with the version
       │
       ├─ plan        reads nothing secret: is this the release commit, is ci green, is the tag
       │              absent or at this commit, is the release already public, is the pinned
       │              Zigbox version on zigbox.org
       ├─ mac-check   macos-15: the unit tests that build on macOS, at the release commit
       ├─ preflight   env release-publish: App token mints for the tap and the site, the tap's
       │              Formula/zigcube.rb readable (or absent, the first time), site deploy.yml found
       ├─ draft       a DRAFT release (--draft --target <sha>), notes from docs/releases/<v>.md
       │              ── nothing above wrote anything public; nothing below does until `publish` ──
       ├─ linux       env release ┐ the owner's ONE approval covers both
       │    build both architectures (servers in the Rocky 9 container), release-sign.sh,
       │    release-assets, SHA256SUMS and SHA256SUMS.asc, attach all of it to the draft
       ├─ mac         env release ┘ macos-15 (hosted)
       │    zcube for arm64 and x86_64, lipo, sign, notarize, check, attach
       │    zcube-<v>-macos-universal.zip, its .sha256, SHA256SUMS.macos and zigcube.rb
       ├─ prepare     env release-publish: the draft holds exactly the expected assets, both sums
       │              files match, SHA256SUMS.asc is by a subkey of the pinned key (checked against
       │              docs/releases/zigbox-release-key.asc), Release's Valid-Until has 14+ days, the
       │              tap diff touches only url, version and sha256
       ├─ publish     the draft becomes the release; THIS creates the tag, at the release commit
       ├─ tap         env release-publish: commit Formula/zigcube.rb to Zigbox/homebrew-tap main
       ├─ site        repository_dispatch to Zigbox/website, wait for the deploy, check the
       │              zigcube suite is served
       └─ verify      ubuntu: install zigbox-dev from zigbox.org, zcube version;
                      macos-15: the public zip (signature, Gatekeeper, both architectures),
                      brew install zigbox/tap/zigcube, zcube version, brew test zigcube
```

`test` (Linux: `release-sign.sh` with a throwaway RSA 4096 key, the refresh's refusals),
`mac-test` (`macos-15`: a throwaway self-signed identity in a temporary keychain, no notarization,
`zcube version`, `zcube --help`, `zcube local` refusing in one line) and `draft-test` (a throwaway
prerelease draft: upload, download, publish, tag, then deleted) run on pull requests that touch
what the release reads, with no secret. `mac-test` never runs for a pull request from a fork.

### Re-runs, refusals, prereleases

As in Zigbox, every job is idempotent: a draft is reused (target must match, notes refreshed,
assets replaced with `--clobber`); a release already public skips `draft` to `publish` and goes on to
`tap`, `site`, `verify`; a tag at another commit is refused by `plan` before anything is written.
By hand, `workflow_dispatch` from `main` with the version finds the commit that added
`docs/releases/<version>.md` along `main`'s first parents.

`X.Y.Z-rc.N` is published as a prerelease, not marked latest, and still writes the tap formula, so
a dry run's formula is reverted by hand afterwards. **Trap for slice 3:** zigbox.org's deploy takes
the newest release *excluding prereleases* (both its steps), so an `rc` never reaches
`zigbox.org/apt/dists/zigcube`, and `site`'s served-suite check and `verify`'s apt install cannot
pass for one. Zigbox's `verify` does not hit this (it checks the Mac zip and the tap only). Slice 3
must decide: skip those two checks for a prerelease and say so in the run's summary, or test the
`rc`'s asset some other way. Not decided here.

## Environments, secrets and variables

All in `Zigbox/zigcube`, as environment secrets and variables (never repository secrets). The
values are copies of Zigbox's, except where the setup guide below recommends a second App or notary
key; no value is new key material.

| Environment | Protection | Secrets | Variables | Jobs |
|---|---|---|---|---|
| `release` | owner as required reviewer, "Prevent self-review", deployments from `main` only | `ZIGBOX_SIGNING_KEY`, `ZIGBOX_SIGNING_PASSPHRASE`, `MAC_CERT_P12`, `MAC_CERT_PASSWORD`, `MAC_NOTARY_KEY` | `MAC_NOTARY_KEY_ID`, `MAC_NOTARY_ISSUER_ID` | `linux`, `mac` |
| `release-publish` | no reviewer, deployments from `main` only | `RELEASE_APP_PRIVATE_KEY` | `RELEASE_APP_ID` | `preflight`, `prepare`, `tap`, `site` |
| `package-refresh` | no reviewer, deployments from `main` only | `ZIGBOX_SIGNING_KEY`, `ZIGBOX_SIGNING_PASSPHRASE`, `RELEASE_APP_PRIVATE_KEY` | `RELEASE_APP_ID` | `package-refresh.yml` |

What each holds:

| Name | Kind | What it is |
|---|---|---|
| `ZIGBOX_SIGNING_KEY` | secret | the signing subkey's secret export, ASCII-armored, primary stubbed (`gpg --armor --export-secret-subkeys "$SUBKEY"'!'`) |
| `ZIGBOX_SIGNING_PASSPHRASE` | secret | that export's passphrase |
| `MAC_CERT_P12` | secret | the Developer ID Application certificate and its key, `.p12`, base64 |
| `MAC_CERT_PASSWORD` | secret | the `.p12` export password |
| `MAC_NOTARY_KEY` | secret | an App Store Connect API key, the `.p8` file's contents, role Developer |
| `MAC_NOTARY_KEY_ID`, `MAC_NOTARY_ISSUER_ID` | variables | that key's Key ID and the team's Issuer ID |
| `RELEASE_APP_ID` | variable | the App ID of the GitHub App "Zigbox Release" |
| `RELEASE_APP_PRIVATE_KEY` | secret | a private key (`.pem`) of that App |

Not a secret or a variable: the primary key's fingerprint
`09991DC39816D3C914E2A22C5AB00BC328B7DBB7`, written in `release.yml` and `package-refresh.yml` as
`ZIGBOX_SIGNING_FPR` (reviewed code), and the public key `docs/releases/zigbox-release-key.asc`.
`GITHUB_TOKEN` (the draft, `publish`, the release uploads) needs `contents: write` on
`Zigbox/zigcube` only, in jobs that hold no signing secret.

## Bill of materials

| # | Item | Kind | Where | Owner of it | Exists? |
|---|---|---|---|---|---|
| 1 | GitHub App "Zigbox Release": Contents read and write, Metadata read, Actions read; installed on `homebrew-tap` and `website` only | GitHub App | Zigbox org | owner | exists; unchanged (not installed on `zigcube`, no new permission) |
| 2 | Environment `release` | environment | Zigbox/zigcube | owner | new |
| 3 | Environment `release-publish` | environment | Zigbox/zigcube | owner | new |
| 4 | Environment `package-refresh` | environment | Zigbox/zigcube | owner | new |
| 5 | `ZIGBOX_SIGNING_KEY`, `ZIGBOX_SIGNING_PASSPHRASE` in `release` and `package-refresh` | secrets | Zigbox/zigcube | owner | new copies of existing values |
| 6 | `MAC_CERT_P12`, `MAC_CERT_PASSWORD`, `MAC_NOTARY_KEY`; `MAC_NOTARY_KEY_ID`, `MAC_NOTARY_ISSUER_ID` in `release` | secrets, variables | Zigbox/zigcube | owner | new copies |
| 7 | `RELEASE_APP_PRIVATE_KEY`, `RELEASE_APP_ID` in `release-publish` and `package-refresh` | secret, variable | Zigbox/zigcube | owner | new copies (a second `.pem` recommended) |
| 8 | Tag ruleset on `v*`: only `github-actions` may create | ruleset | Zigbox/zigcube | owner | recommended |
| 9 | Website `deploy.yml` second fetch step, `check-zigcube-asset.sh` and its test, `AGENTS.md` | workflow, docs | Zigbox/website | owner applies the patch | written (patch in this directory) |
| 10 | `Formula/zigcube.rb` | file | Zigbox/homebrew-tap | written by `tap` | new on the first release |
| 11 | Hosted runners `ubuntu-24.04`, an arm64 Linux runner, `macos-15` | runners | GitHub | GitHub | exist (*per slice 3*: the arm64 label) |
| 12 | `release.yml`, `package-refresh.yml` | workflows | Zigbox/zigcube | implementer | slice 3 |
| 13 | Actions `setup-gh`, `find-draft`, `tap-formula`, `mac-check-zip`, `setup-zig-macos`, pinned as Zigbox's | actions | `.github/actions/` | implementer | slice 3 (`setup-zig`, `install-apt`, `zig-cache` exist) |
| 14 | `zig build packages`, `packages-check`, `packages-redate`, `release-assets`, `release-sign.sh`, `build-release-bin.sh` | code | Zigbox/zigcube | implementer | slice 1, done |
| 15 | `zig build mac-release`, `mac-check-zip` | code | Zigbox/zigcube | implementer | slice 2 |
| 16 | This file and packaging.md | docs | Zigbox/zigcube | implementer | slice 4 |

Not needed: a new GitHub App or App permission, a new signing key, a second keyring, a
self-hosted runner, a `release-tag` environment, `tag.yml`.

## Security notes

Zigbox's apply unchanged; the ones that matter for the setup:

- The `release` environment's required reviewer and its `main`-only policy are what keep a pull
  request away from the key and the Developer ID. Set both before setting any secret in it.
- The Mac secrets reach a GitHub-hosted macOS VM that is destroyed after the job; they enter through
  `env:` of the signing step into mode-600 files and a temporary keychain removed in an `always()`
  step (*per slice 3*, copied from Zigbox).
- The App can write the tap and the website, nothing else; it is not installed on `Zigbox/zigcube`
  and must not be. Its key is in `release-publish` and `package-refresh` only, tokens are minted per
  job for the one repository the job needs.
- Nothing prints a secret and no secret is a command-line argument, here or in the setup guide:
  every value goes in through `gh`'s standard input or its prompt.
- Every tool is pinned (Zig and `gh` by SHA-256, actions by commit SHA), and every checkout sets
  `persist-credentials: false` (*per slice 3*).

## Setup guide (owner, once)

Do this after Zigbox's own setup (Zigbox's `automation.md`, "Setup guide"), whose App, key and
certificate this reuses. Every value goes in through standard input or a prompt. Run the commands
on the machine that holds the primary key and the Developer ID certificate, with `gh` logged in as
the owner.

**1. The App: nothing to install.** Check that "Zigbox Release" is installed on `homebrew-tap` and
`website` and not on `zigcube`: Zigbox organisation → Settings → GitHub Apps → Zigbox Release →
Configure → Repository access. Leave it as it is. Note the **App ID** (App settings → General).

Recommended: give Zigcube its own private key of the same App, so either repository's copy can be
revoked alone. App settings → General → Private keys → **Generate a private key** (a `.pem`
downloads; Zigbox's key stays valid). If you keep a copy of Zigbox's `.pem` instead, use that
file; the steps are the same.

**2. The three environments.** In the browser: `Zigbox/zigcube` → Settings → Environments → New
environment, three times:

- `release`: tick **Required reviewers**, add yourself, tick **Prevent self-review**; Deployment
  branches and tags → **Selected branches and tags** → add rule `main` (type branch).
- `release-publish`: no reviewer; Selected branches and tags → `main`.
- `package-refresh`: no reviewer; Selected branches and tags → `main`.

Or with `gh` (the reviewer is your own user id):

```bash
for env in release release-publish package-refresh; do
  gh api -X PUT repos/Zigbox/zigcube/environments/$env -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true'
  gh api -X POST repos/Zigbox/zigcube/environments/$env/deployment-branch-policies -f name=main -f type=branch
done
```

```bash
gh api -X PUT repos/Zigbox/zigcube/environments/release -F prevent_self_review=true -F 'reviewers[][type]=User' -F "reviewers[][id]=$(gh api user --jq .id)" -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true'
```

Check: `gh api repos/Zigbox/zigcube/environments --jq '.environments[] | [.name, ([.protection_rules[].type] | join(","))] | @tsv'`
lists `release` with `required_reviewers` and `branch_policy`, and the other two with
`branch_policy`.

**3. The signing subkey, into `release` and `package-refresh`.** `$SUBKEY` is the signing
subkey's fingerprint (Zigbox's packaging.md, "One-off key setup", shows how to find it).

```bash
for env in release package-refresh; do
  gpg --armor --export-secret-subkeys "$SUBKEY"'!' | gh secret set ZIGBOX_SIGNING_KEY --env $env --repo Zigbox/zigcube
  gh secret set ZIGBOX_SIGNING_PASSPHRASE --env $env --repo Zigbox/zigcube
done
```

(`gh` prompts for the passphrase each time.)

**4. The Developer ID certificate, into `release`.** Keychain Access → login → My Certificates →
"Developer ID Application: …" → right-click → Export → `.p12`, with an export password.

```bash
base64 -i ~/Desktop/DeveloperID.p12 | gh secret set MAC_CERT_P12 --env release --repo Zigbox/zigcube
```

```bash
gh secret set MAC_CERT_PASSWORD --env release --repo Zigbox/zigcube
```

Delete the `.p12` afterwards.

**5. The notary key, into `release`.** The `.p8` downloads only once. If you kept Zigbox's
`AuthKey_<KEYID>.p8`, use it. Otherwise App Store Connect → Users and Access → Integrations → App
Store Connect API → Team Keys → generate a key with role **Developer** for Zigcube (a credential for
the same team, not a new signing identity), and note its Key ID; the Issuer ID is the team's.

```bash
gh secret set MAC_NOTARY_KEY --env release --repo Zigbox/zigcube < ~/Downloads/AuthKey_KEYID.p8
```

```bash
gh variable set MAC_NOTARY_KEY_ID --env release --repo Zigbox/zigcube --body KEYID
```

```bash
gh variable set MAC_NOTARY_ISSUER_ID --env release --repo Zigbox/zigcube --body ISSUER-UUID
```

**6. The App's id and key, into `release-publish` and `package-refresh`.** Replace `123456` with the
App ID and the path with the `.pem`.

```bash
for env in release-publish package-refresh; do
  gh variable set RELEASE_APP_ID --env $env --repo Zigbox/zigcube --body 123456
  gh secret set RELEASE_APP_PRIVATE_KEY --env $env --repo Zigbox/zigcube < ~/Downloads/zigbox-release.private-key.pem
done
```

Delete the `.pem` afterwards (the App can issue another).

**7. Recommended: a tag ruleset.** `publish` refuses a tag that appeared since `plan`, but that
leaves seconds of window. `Zigbox/zigcube` → Settings → Rules → Rulesets → New ruleset → New tag
ruleset: target `v*`, restrict creations, bypass list the `github-actions` identity only. Sessions
cannot set rulesets.

**8. The website.** Apply [`website-zigcube-suite.patch`](website-zigcube-suite.patch) to
`Zigbox/website` and merge it (packaging.md, "The site deploy", has the commands). Until then the
deploy ignores Zigcube's asset and `site` fails after `publish`.

**9. Check.**

```bash
for env in release release-publish package-refresh; do
  echo "== $env"; gh secret list --env $env --repo Zigbox/zigcube; gh variable list --env $env --repo Zigbox/zigcube
done
```

Expect, in `release`: secrets `ZIGBOX_SIGNING_KEY`, `ZIGBOX_SIGNING_PASSPHRASE`, `MAC_CERT_P12`,
`MAC_CERT_PASSWORD`, `MAC_NOTARY_KEY` and variables `MAC_NOTARY_KEY_ID`, `MAC_NOTARY_ISSUER_ID`; in
`release-publish`: `RELEASE_APP_PRIVATE_KEY` and `RELEASE_APP_ID`; in `package-refresh`:
`ZIGBOX_SIGNING_KEY`, `ZIGBOX_SIGNING_PASSPHRASE`, `RELEASE_APP_PRIVATE_KEY` and `RELEASE_APP_ID`.
Nothing at repository level (`gh secret list --repo Zigbox/zigcube` shows none of these). Tell the
supervisor; the `v0.5.1-rc.1` dry run follows.

## Every year

The signing subkey's renewal now sets `ZIGBOX_SIGNING_KEY` in four environments (`release` and
`package-refresh` in both repositories) and copies the public key into both: packaging.md, "Yearly
renewal". A Developer ID certificate renewal sets `MAC_CERT_P12` and `MAC_CERT_PASSWORD` in both
repositories' `release`. If a second App private key or notary key was made for Zigcube in steps 1
or 5, revoking Zigbox's does not revoke Zigcube's, and the other way round.

## A release afterwards

1. Zigbox's release for the version Zigcube pins is public, and zigbox.org serves it.
2. The supervisor merges Zigcube's release PR (version bumped, `docs/releases/<v>.md` written,
   gates quoted).
3. `ci` goes green on `main`; `release` runs `plan`, `mac-check`, `preflight` and makes the draft.
4. The owner opens the run, checks its commit is the release commit on `main`, and approves
   `release` once (`linux` and `mac` wait together).
5. `prepare`, `publish`, `tap`, `site`, `verify` run; the supervisor reports the run link and
   updates README and the site's status.
6. If a job fails: re-run the failed jobs, or start `release` from `main` with the version. A
   failure before `publish` left a draft; delete it on the releases page to start clean. After a
   prerelease, revert `Formula/zigcube.rb` in the tap by hand.

## Slices

1. **Done:** the packages, signing, release assets, install test.
2. **Next:** `zig build mac-release`, `mac-test`.
3. **Next:** `release.yml`, `package-refresh.yml`, the actions; replaces every *per slice 3* above.
4. **This:** this file, packaging.md, the website patch.
5. **Owner:** the setup guide above, and merging the website change.
6. **Supervisor:** the `v0.5.1-rc.1` dry run (after Zigbox's), cleanup, the run link in the decision.
