# C3 input: a signed macOS `zcube`

Owner, 2026-11-04: ship a signed, notarized macOS build of the `zcube` command in C3. This is a
list to fold into C3's brief when it is written, not a brief. It is one small slice.

## Scope

- **`zcube` only.** `zcube-server` and `zcube-agent` stay Linux: the server links SQLite and libpq,
  and the agent runs Zigbox containers, which need Linux. A Mac user talks to a remote server.
- **Reuse Zigbox's macOS release path** (Zigbox `docs/briefs/M4b-mac.md`, `docs/demos/m4b.md`,
  `.github/workflows/mac.yml`): a `zig build mac-release` step that builds ReleaseSafe for
  `aarch64-macos` and `x86_64-macos`, signs with the Developer ID in the owner's keychain,
  notarizes with `xcrun notarytool` (`-Dnotarize=true`, a keychain profile, never a credential on
  the command line or in a log), and writes a Homebrew formula with the URL and hash filled in.
- **Distribution:** a formula in the `Zigbox/homebrew-tap` tap, `brew install Zigbox/tap/zigcube`.
- **CI:** a macOS job builds and runs `zcube`'s unit tests and `zcube --help` unsigned on every
  release PR, as Zigbox's `mac.yml` does. CI never signs or releases.

## Cost and constraints

- Signing and notarizing happen on the owner's Mac, once per release, as for Zigbox: the
  certificate and notary credentials stay in that keychain.
- A Mach-O cannot be stapled: the notarization ticket stays with Apple and Gatekeeper checks it
  online on first run of a quarantined copy (see Zigbox `docs/demos/m4b.md`).

## Unknowns to settle first

1. Whether `zcube` builds for macOS at all today. It may import Linux-only code (the local mode,
   process supervision, `/proc`). Find out before the slice is sized; cut what does not build
   rather than port it.
2. Whether `zcube local up` can mean anything on a Mac (it would need Zigbox's macOS VM and a
   Linux agent inside it). Default: not in C3; `zcube local` on macOS refuses with one line saying
   why and what to use instead.

## Demo

On the owner's Mac: `brew install Zigbox/tap/zigcube`, `spctl -a -vv -t install` on the binary
says `accepted, source=Notarized Developer ID`, and `zcube get nodes --server <a Linux server>`
lists that server's nodes.
