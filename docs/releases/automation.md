# Release automation: the flow, the checks, the owner's setup

Status: built in 0.6.0 (decisions
[2026-11-17-zigcube-release-workflow.md](../decisions/2026-11-17-zigcube-release-workflow.md),
the owner's, and [2026-11-17-release-workflow-built.md](../decisions/2026-11-17-release-workflow-built.md),
what was built and how it differs from Zigbox's). Not yet run on a real release: the first run
is 0.6.0's. Modelled on Zigbox's `docs/releases/automation.md` and `release.yml`, cut down to
what Zigcube ships.

## Goal

The owner's only act in a release is **one approval of the `release` environment**. Everything
before it (the checks, the draft, the build, the assets on the draft) and the one step after it
(publishing the draft, which makes the tag) runs without anyone. The release gates in AGENTS.md
("Releases") do not change: the release PR still carries the fleet's tracker line, the Jepsen
result where it applies and both review verdicts, and the supervisor still merges it.

Two rules shape the flow, as in Zigbox:

- **Draft first, publish last.** The release is a draft until every asset exists and has been
  checked. A draft has no tag, so a failure before the last step leaves a draft and nothing else:
  no tag and no release anyone outside the repository's writers can see.
- **The tag is never made by hand** once this workflow exists, unless the owner writes a
  go-ahead for that release in `docs/decisions/`. Publishing the draft makes it.

## What a release ships

Attached to the GitHub release `v<version>`:

| Asset | What it holds |
|---|---|
| `zigcube-<version>-x86_64-linux.tar.gz` | `zigcube-<version>-x86_64-linux/` with `bin/zcube`, `bin/zcube-server`, `bin/zcube-agent`, `LICENSE`, `COMMIT` |
| `zigcube-<version>-aarch64-linux.tar.gz` | the same for aarch64 |
| `SHA256SUMS` | `sha256sum -c` format, one line per tarball |

The binaries are ReleaseSafe, for a baseline CPU, glibc 2.39 (Ubuntu 24.04 and later), and
`zcube-server` links the system's `libsqlite3.so.0` and `libpq.so.5` dynamically (on Ubuntu:
`apt install libsqlite3-0 libpq5`). Both architectures build against Ubuntu 24.04's own libpq:
`release-libs.sh` removes any apt.postgresql.org source (the runner image has one) and installs
the newest libpq5 Ubuntu serves for both amd64 and arm64, downgrading the host's if it must
(libpq5 is `Multi-Arch: same`, so the two must be the same version). It prints the version of
each package it linked, in the `build` job's log; reproducing a release byte for byte needs
those versions. `COMMIT` is the release commit. The tarballs are
reproducible: the same commit gives the same bytes (mtime 0, no owner names, a fixed order).
The release notes are `docs/releases/<version>.md` at the release commit, written for readers.

`zig build release` builds all of it into `zig-out/release` (`src/dist.zig`, mode `release`).
It refuses a tree without `.git` or with uncommitted changes to tracked files. On an x86_64
Ubuntu 24.04 host the aarch64 half needs the arm64 libraries:
`sudo .github/release-libs.sh DIR` installs them and prints DIR, then
`zig build release -Drelease-lib-dir-aarch64=DIR`. `.github/release-check.sh zig-out/release
<version> <commit>` checks the result.

**No signing key is needed, and nothing is signed.** `SHA256SUMS` is not signed: it detects a
damaged download, not a replaced one, since whoever could replace a tarball could replace
`SHA256SUMS` too. Who built it is GitHub's record: the assets are attached by `github-actions` in
the run the release links to. The release page says so: the workflow appends a footer to the
notes naming the release commit and the run that attached the assets.
Signing (a key, like Zigbox's `SHA256SUMS.asc`) would be a new decision for the owner.

## The flow

One workflow, `.github/workflows/release.yml`, one run, a `needs:` chain.

```
release PR merged to main (supervisor; version in build.zig.zon, notes in docs/releases/<v>.md)
  └─ ci green on that main commit  ──►  release.yml (workflow_run), or by hand with the version
       │
       ├─ plan      reads nothing secret: is this the release commit, is ci green on it, is the
       │            release already public, is the tag absent or at this commit
       ├─ draft     a DRAFT release (--draft --target <sha>), notes from docs/releases/<v>.md;
       │            an existing draft for the tag is reused and its notes refreshed
       ├─ build     zig build release; release-check.sh (sums, exact contents, COMMIT, ELF
       │            machine, each binary's version, aarch64 under qemu); hand the assets on as
       │            a workflow artifact and the SHA-256 of SHA256SUMS to attach and publish.
       │            contents: read, no token that can write, no gh
       ├─ attach    checks the artifact against that SHA-256 and `sha256sum -c`; deletes any
       │            other asset on the draft; attaches the three (--clobber)
       │            ── nothing above is public; the owner can open the draft now ──
       └─ publish   env `release`: the owner's ONE approval. The draft must hold exactly the
                    three assets, with the SHA256SUMS build checked, and they must match it;
                    the tag must be absent or at the release commit; then the draft becomes
                    the release, which makes the tag, and the tag is checked to be at <sha>
```

**The release commit** is the commit of `main` that added `docs/releases/<version>.md`, with that
version in `build.zig.zon`. A merged pull request's merge commit counts (`--first-parent`), as
`workflow_run` sees it. A green `ci` on any other commit of `main` stops `plan` quietly (a notice,
no failure): most commits are not releases. A version with a `-` (such as `0.6.0-rc.1`) is
published as a prerelease and never marked latest; nor is a version lower than the newest
published release (a fix to an older line), so `latest` never goes backwards.

**Who starts it.** `ci` finishing green on a push to `main` of this repository. A fork's pull
request whose branch is named `main` never starts it. By hand: Actions → release → Run workflow,
Use workflow from `main`, with the version; that is also how a failed or half-done release is
finished.

**`plan` fails closed on an unprotected environment.** GitHub creates an environment the moment
a job names it, with no protection, and runs that job at once; a private repository on a free
plan cannot hold required reviewers at all. Either way `publish` would run without the owner's
approval. So `plan` (once it knows the commit is a release) and `publish` (before anything else)
run `.github/release-env.sh`, which fails unless `release` exists with at least one required
reviewer, `can_admins_bypass: false` and a deployment policy that admits the branch `main` and
nothing else. On a private repository without a paid plan the workflow therefore refuses every
release; Zigcube is public.

### Every job is idempotent

**Re-run all jobs** on a failed run, or starting `release` by hand with the version, finishes a
half-done release. ("Re-run failed jobs" is not enough: it reuses the old jobs' outputs, and after
a publish that made the release public its `find-draft` fails, since there is no draft.)

- `plan` stops quietly when the release is already published, after checking that its tag is
  at the release commit (it fails otherwise).
- `draft` reuses the one draft for the tag (`.github/actions/find-draft`), and fails if there are
  two or if the draft targets another commit: delete the wrong draft and run again.
- `build` rebuilds (the bytes are the same for the same commit); `attach` deletes any asset on
  the draft that is not one of the three and replaces the three (`gh release upload --clobber`).
- `publish` checks again that the draft holds what `build` checked.

### What protects the release

- Only GITHUB_TOKEN is used. The workflow defaults to `contents: read`; `draft`, `attach` and
  `publish` ask for `contents: write`, `plan` and `publish` for `actions: read` (to see `ci`'s
  result and the environment's protection). There are no secrets and no variables, so none can
  be printed or put on a command line.
- **The build holds no write token.** `build` runs the release commit's code (`build.zig`, the
  build, and steps under `sudo`, which can read a job's token from the runner's memory), so it
  has `contents: read`, no `GH_TOKEN` and no `gh`. It hands the assets on as a workflow artifact
  (`actions/upload-artifact`, kept 7 days) with the SHA-256 of `SHA256SUMS` as a job output;
  `attach`, which runs none of the commit's code, checks the artifact against both before
  uploading. ci.yml's `release` job fails if a `release.yml` job that runs `zig build` names
  `contents: write`, `GH_TOKEN`, `github.token` or a secret.
- The `release` environment holds no secret. Its only job is the approval, and its deployment
  branch policy lets only runs from `main` use it.
- Every tool is pinned: Zig by SHA-256 (`setup-zig`), `gh` 2.74.0 by SHA-256 (`setup-gh`), every
  action by full commit SHA. Every checkout sets `persist-credentials: false`. The release build
  uses no cache at all: `setup-zig` runs with `cache: 'false'`, so Zig is downloaded and its
  SHA-256 checked every time (a cache hit would skip the check).
- Local actions and the release scripts load from the workflow's own commit
  (`github.workflow_sha`, checked out sparsely at `.release-tools`), not from the release
  commit's checkout, so a fix to the release tooling reaches a release commit made before it.
  ci.yml's `release` job fails if `release.yml` names one outside `.release-tools`.
- A tag that exists at another commit is never touched: `plan` refuses it, and `publish` checks
  again just before publishing (the approval can wait for hours).

### Testing a change to the workflow

ci.yml's `release` job runs on every pull request that changes `release.yml`,
`.github/release-*.sh`, `.github/actions/setup-gh` or `find-draft`, or `src/dist.zig`, and on
every full run (`build.zig` and the rest of `.github/` run everything; `.github/ci-changes.sh`).
It runs shellcheck on `.github/release-*.sh`, the write-token guard above, `release-libs.sh`,
`zig build release` and `release-check.sh`, with `contents: read`: no draft, no upload, no tag.
A pull request that adds `docs/releases/<version>.md` runs every CI job, as a release branch
does, so a release commit is never "green" with nothing run. What it cannot try is the GitHub side (`plan`'s API calls, the
environment check, the draft, the artifact hand-off, the upload, the approval and the publish): those first run on a real release. A failure
there leaves at most a draft; delete it (`gh release delete v<version> --repo Zigbox/zigcube`,
which never deletes a tag unless asked with `--cleanup-tag`) and run again by hand.

## Bill of materials

| # | Item | Kind | Owner of it | Exists? |
|---|---|---|---|---|
| 1 | Environment `release`: the owner as required reviewer, no admin bypass, deployments from `main` only, no secrets | environment | owner | **new: see the setup below** |
| 2 | GitHub-hosted runner `ubuntu-24.04` | runner | GitHub | exists |
| 3 | Zig 0.17.0, `gh` 2.74.0 (SHA-256 pinned), `actions/checkout`, `actions/cache`, `actions/upload-artifact`, `actions/download-artifact` (full SHA) | tools | implementer | exist (`setup-gh` new) |
| 4 | `release.yml`: `plan`, `draft`, `build`, `attach`, `publish` | workflow | implementer | new |
| 5 | `.github/actions/setup-gh`, `find-draft` (copied from Zigbox) | actions | implementer | new |
| 6 | `.github/release-libs.sh`, `release-check.sh`, `release-tag.sh`, `release-env.sh` | scripts | implementer | new |
| 7 | `zig build release` (`src/dist.zig` mode `release`) | code | implementer | new |
| 8 | ci.yml `release` job, its `.github/ci-changes.sh` rule and table rows | CI | implementer | new |
| 9 | `docs/releases/<version>.md` for each release, written for readers | notes | supervisor | per release |

Recommended, not required: **a tag ruleset** that lets only the release workflow create `v*`
tags (see step 4 below). `publish` checks the tag just before publishing, which leaves a window
of seconds; the ruleset closes it.

## Setup guide (owner, once)

Run these on your own machine with the GitHub CLI, signed in as an account with admin rights on
`Zigbox/zigcube`. No value in them is secret.

**0. The GitHub CLI.** Install it (https://cli.github.com, or `brew install gh`, or
`sudo apt install gh`), then sign in and check:

```bash
gh auth login
```

```bash
gh auth status
```

**1. The `release` environment, with you as its required reviewer.** This creates it (or updates
it, if it exists) with your own account, as `gh` is signed in, as the one reviewer, and
deployments limited to the branches you list in step 2, and admins (you included) unable to
skip the approval. `prevent_self_review` is off on purpose: you may be the account that merged
the release PR, and you must still be able to approve.

```bash
gh api user --jq '{reviewers: [{type: "User", id: .id}], prevent_self_review: false, wait_timer: 0, can_admins_bypass: false, deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}' | gh api -X PUT repos/Zigbox/zigcube/environments/release --input -
```

(Required reviewers are free on a public repository, which Zigcube is. On a private repository
they need a paid plan; without one there is no reviewer to keep, and the workflow then refuses
every release: see step 3.)

**2. Only `main` may deploy to it.**

```bash
gh api -X POST repos/Zigbox/zigcube/environments/release/deployment-branch-policies -f name=main -f type=branch
```

**3. Check it.** The first command should print your login under `reviewers`,
`can_admins_bypass: false` and `custom_branch_policies: true`; the second should list one policy,
`main`. **If `reviewers` is empty, stop:** do not merge a release PR until it is not (the
workflow would refuse the release anyway, in `plan`).

```bash
gh api repos/Zigbox/zigcube/environments/release --jq '{reviewers: [.protection_rules[] | select(.type == "required_reviewers") | .reviewers[].reviewer.login], can_admins_bypass, branch_policy: .deployment_branch_policy}'
```

```bash
gh api repos/Zigbox/zigcube/environments/release/deployment-branch-policies --jq '.branch_policies[].name'
```

**4. Recommended: protect `v*` tags.** Sessions cannot set rulesets. In the browser: Zigbox/zigcube
→ Settings → Rules → Rulesets → New ruleset → New tag ruleset; target tags matching `v*`; restrict
creations, updates and deletions; add GitHub Actions (`github-actions`) to the bypass list. If the
ruleset blocks the release's own tag, the first `publish` fails and says so; nothing is public
then, and removing the restriction and re-running finishes the release.

Nothing else: no secret, no variable, no runner, no App.

## A release, step by step

1. The supervisor's release PR sets the version in `build.zig.zon` and adds
   `docs/releases/<version>.md` (notes for readers), with the gates AGENTS.md "Releases" names.
2. The supervisor merges it. `ci` runs on `main`; when it is green, `release` starts.
3. `plan`, `draft`, `build` and `attach` run (about 10 minutes; the build is from nothing). The draft, with
   its notes and three assets, is under Releases for the repository's writers.
4. GitHub asks you to review the `release` deployment (a notification, and the run's page:
   Review deployments → `release` → Approve and deploy). Approve it.
5. `publish` makes the release public and the tag `v<version>` at the release commit.

If a step fails before `publish`, the run's log says why; fix the cause (a pull request, if it
is in the tooling) and run `release` by hand from `main` with the version, or use "Re-run all
jobs" on the failed run when nothing needed fixing.
