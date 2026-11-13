# The macOS CI job runs on zcube's own paths; the Linux job cross-compiles on every change

*Decided 2026-11-13, by the slice (C3 slice 15).*

CI's `macos` job (zcube built, unit-tested and run on a GitHub-hosted Apple silicon runner) is not
one of the jobs a path no rule names turns on (`jobs` in `.github/ci-changes.sh`). It runs on a
full run (a push to main, a `claude/release-*` pull request, the `full-ci` label) and on a pull
request that changes a path `is_macos` names: `src/zcube.zig`, `src/cli*.zig`,
`src/mac_release.zig`, `packaging/homebrew/*`, `build.zig`, `build.zig.zon`, CI's workflow,
the macOS setup action and the classifier.

Why: a hosted macOS minute is billed at ten Linux minutes on a private repository, and most
changes cannot break `zcube` on macOS without also breaking its compile. That compile is checked
on every change, without a Mac: `zig build mac-cross` (both macOS targets) is a step of the Linux
check job and a gate of `zig build check`. What only the macOS job catches is a test or a run
that behaves differently there, and that lives in the command line's own files. The brief asked
for the job on every release PR; a release PR is a full run, so it gets it.

The job is a hosted runner rather than Zigbox's self-hosted one: `zcube` needs no
Virtualization.framework, and a hosted runner holds nothing a fork's pull request could reach.
It holds no secret.

Where: `.github/ci-changes.sh`, `.github/ci-changes-test.sh` (`check_macos`),
`.github/workflows/ci.yml` (`macos`), `docs/macos.md`.
