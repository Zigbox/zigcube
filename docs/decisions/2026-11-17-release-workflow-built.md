# The release workflow as built, and where it differs from Zigbox's

*Decided 2026-11-17, by the slice (0.6.0, release workflow).*

The owner's decision ([2026-11-17-zigcube-release-workflow.md](2026-11-17-zigcube-release-workflow.md))
asked for Zigbox's release model with one approval gate. What was built: `release.yml` runs
`plan`, `draft`, `build` and `publish` after a green `ci` on the release commit of `main` (or by
hand with the version), and only `publish` uses the environment `release`. It ships
`zcube`, `zcube-server` and `zcube-agent` for x86_64-linux and aarch64-linux (ReleaseSafe, in one
tarball each, built by `zig build release`) and `SHA256SUMS`, with the notes from
`docs/releases/<version>.md`. The runbook is [docs/releases/automation.md](../releases/automation.md).

Where it differs from Zigbox's `release.yml`, and why:

- **No deb, rpm, macOS, Homebrew tap, apt/dnf trees, site update, `verify`, `preflight`,
  `mac-check` or `prepare`.** The brief left packages and macOS out, and with them every job that
  only serves them. The checks of Zigbox's `prepare` that still apply (the draft holds exactly the
  assets that were built and checked) are in `publish`.
- **One environment, not two.** Zigbox has `release` (secrets) and `release-publish` (approval).
  Zigcube has no secrets, so one environment, `release`, carries the approval, on `publish`, after
  the assets are on the private draft: the owner can look at the draft before approving.
- **No signing key and no secrets.** Only GITHUB_TOKEN. `SHA256SUMS` is not signed (no
  `SHA256SUMS.asc`); signing would need a key and is a new decision for the owner.
- **aarch64 is cross-compiled on one x86_64 runner** (`ubuntu-24.04`) against Ubuntu's arm64
  libsqlite3 and libpq from `ports.ubuntu.com` through multiarch (`.github/release-libs.sh`), and
  checked under `qemu-aarch64`. libpq-dev cannot be installed for two architectures at once, so
  the script links `libpq.so` to the arm64 `libpq.so.5` in a directory passed as
  `-Drelease-lib-dir-aarch64`. An arm64 runner would cost a second job and a second Zig set-up
  for the same bytes.
- **The test job is ci.yml's `release` job**, routed by `.github/ci-changes.sh` (its own rule for
  the release files and `src/dist.zig`, and every full run), instead of a `pull_request` trigger
  on `release.yml` plus a `release-test` branch. It builds and checks; it publishes nothing and
  has `contents: read`. There is no draft test: the GitHub side first runs on a real release, and
  a failure there leaves at most a draft.
- **The release scripts load from `.release-tools`** (the workflow's own commit), like the local
  actions, so a fix to them reaches an older release commit; ci.yml's `release` job fails if
  `release.yml` names a script or action outside it.
- **An already-published release stops `plan` quietly**, so a re-run after success is a no-op.
- **`publish` accepts a tag that already names the release commit** (Zigbox refuses any existing
  tag): a re-run after a publish that made the tag but failed its check then finishes. A tag at
  another commit is still refused.
- **No build cache in the release build.** Every release builds from nothing (about ten minutes).

Where: `.github/workflows/release.yml`, `.github/release-libs.sh`, `.github/release-check.sh`,
`.github/release-tag.sh`, `.github/actions/setup-gh`, `.github/actions/find-draft`, `src/dist.zig`
(mode `release`), `build.zig` (`zig build release`), ci.yml's `release` job,
`docs/releases/automation.md`.
