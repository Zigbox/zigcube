# Zigcube releases get Zigbox's release workflow, with one approval

*Decided 2026-11-17, by the owner.*

Zigcube 0.5.2 was released by hand: the owner ran `gh release create` with a target commit and a
notes file, and the first command failed because it read the notes from a checkout the owner did
not have. Zigbox's releases need one act from the owner, an approval of the `release`
environment, and nothing else (Zigbox `docs/releases/automation.md`).

Zigcube gets the same, as a slice of 0.6.0, before the 0.6.0 tag:

- A `release.yml` that starts when `ci` is green on a release commit on `main` (the commit that
  added `docs/releases/<version>.md` with the version in `build.zig.zon`), creates a **draft**
  release at that commit, attaches the release assets and their sums, and checks the draft.
- **One manual approval gate:** a GitHub Environment `release` with the owner as required
  reviewer. Publishing the draft, which creates the tag, happens only after that approval.
- Draft first, publish last, every job idempotent, as in Zigbox: a failed run leaves a draft and
  no tag, and re-running finishes it.
- No secret is printed or put on argv; the tag is never made by hand once the workflow exists,
  unless the owner writes a go-ahead for that release in `docs/decisions/`.

The release notes file is written as notes for readers, not as the supervisor's checklist.

Where: the slice's brief (to be written under `docs/briefs/`); Zigbox `docs/releases/automation.md`
as the model; `docs/retros/0.5.2.md`.
