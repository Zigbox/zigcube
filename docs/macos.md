# zcube on macOS

C3 slice 15 (`docs/briefs/c3.md`, item 15; `docs/briefs/c3-macos-cli.md`). On a Mac, `zcube` is a
client of a `zcube-server` that runs on Linux. `zcube-server` and `zcube-agent` stay Linux: the
server links SQLite and libpq, and the agent runs Zigbox containers.

## What builds

`zcube` alone builds for `aarch64-macos` and `x86_64-macos` from any host, with no code cut: the
command line imports nothing that fails to compile there. The one Linux-only part, `zcube local`
(it starts `zcube-server` and `zcube-agent`, and marks inherited descriptors close-on-exec with
Linux `fcntl`), sits behind a comptime check in `src/cli_local.zig`, so its code is never compiled
for macOS. Both architectures are kept: the release binary is universal, as Zigbox's `zbx` is
(`docs/decisions/2026-11-13-macos-zcube-universal.md`).

`zcube local up` or `down` on macOS refuses before doing anything, with the code `zcube local`
already uses when it cannot start the server or the agent:

```
error[ZC-E0122]: zcube local can't find or start the server or agent
  while  starting the local server and agent
  cause  zcube local runs only on Linux, and this is macos
  fix    run zcube local on a Linux machine, or point zcube at a server:
           zcube --server HOST:PORT get nodes
```

Exit code 2 (environment). `zcube explain E0122` says the same. The golden cases of E0122, E0123
and E0124 run `zcube local up` against fake executables and need Linux, so they run only there.

## Build steps

| Step | What it does | Where it runs |
| --- | --- | --- |
| `zig build cli` | builds and installs `zig-out/bin/zcube` only, for the target given (`-Dtarget=`) | anywhere |
| `zig build test-cli` | the command line's unit and golden tests (`src/cli_tests.zig`), without SQLite, libpq or the console | anywhere |
| `zig build mac-cross` | compiles `zcube` and its tests for both macOS targets, without running them | any host; a gate of `zig build check` and a step of CI's Linux check job |
| `zig build mac-release` | the signed release (below) | the owner's Mac only; elsewhere it fails, saying so |

## The release

`zig build mac-release [-Dnotarize=true] [-Dsign-identity=NAME|-] [-Dnotary-profile=NAME]
[-Dkeychain=FILE]` follows Zigbox's step of the same name (Zigbox `docs/demos/m4b.md`,
"Releasing"; `src/mac_release.zig` here):

1. builds `zcube` ReleaseSafe for `aarch64-macos` and `x86_64-macos` and joins them with `lipo`;
2. signs the universal binary with the Developer ID in the owner's keychain, hardened runtime and
   a secure timestamp, and verifies the signature (no entitlements: `zcube` asks for no protected
   resource);
3. zips it with `ditto` into `zig-out/mac-release/zcube-<version>-macos-universal.zip` and checks
   that the archive holds the same signed code;
4. with `-Dnotarize=true`, submits the zip with `xcrun notarytool submit --keychain-profile
   <profile> --wait`. The default profile is Zigbox's, `zbx-notary`: one Apple account notarizes
   both commands. No credential is ever on a command line or in a log;
5. writes `<zip>.sha256` and `zig-out/mac-release/zcube-resource.rb`.

A Mach-O cannot be stapled: Gatekeeper checks the notarization online the first time a
quarantined copy runs.

`-Dsign-identity=-` signs ad hoc (no certificate, no timestamp) for trying the step.

**Signing and notarization run only on the owner's Mac.** CI never signs or releases, and no
workflow holds a signing or notary secret.

## Homebrew

There is no `zigcube` formula. `zcube` joins `zbx` in the `zigbox` formula of `Zigbox/homebrew-tap`,
so `brew install Zigbox/tap/zigbox` installs both. `packaging/homebrew/zcube-resource.rb` is the
template; `mac-release` fills in the version, the release URL
(`https://github.com/Zigbox/zigcube/releases/download/v<version>/<zip>`) and the SHA-256, and the
result holds three parts to paste into the formula Zigbox's own `mac-release` wrote: a `resource
"zcube"` block, the line in `def install` that installs it, and two test lines (`zcube help`,
`zcube explain E0122`), neither of which reaches a server. That edit is made in the tap, by the
owner, once per release of either project; nothing here pushes to it.

Zigbox's formula has `depends_on arch: :arm64` (Zigbox's VM needs Apple silicon), so through the
formula only the arm64 half of the universal `zcube` is ever installed. The zip itself runs on
Intel Macs too.

## CI

CI's `macos` job (`.github/workflows/ci.yml`) runs on a GitHub-hosted Apple silicon runner
(`macos-15`): `zig build cli`, `zig build test-cli`, `zcube help`, and `zcube local up`, which must
exit 2 with ZC-E0122. It runs on a full run (main, a release branch, `full-ci`) and when a pull
request changes `zcube`'s own files, the build or CI (`is_macos` in `.github/ci-changes.sh`;
`docs/decisions/2026-11-13-macos-ci-paths.md`). Every other change is covered by the Linux check
job's `zig build mac-cross`.

## The demo (owner's Mac)

`brew install Zigbox/tap/zigbox`; `spctl -a -vv -t install $(brew --prefix)/bin/zcube` says
`accepted, source=Notarized Developer ID`; `zcube get nodes --server <a Linux server>` lists that
server's nodes. Not run in the cloud container: it needs a Mac, the owner's keychain and a release.
