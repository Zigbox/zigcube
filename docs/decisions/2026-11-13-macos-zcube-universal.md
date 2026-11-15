# The macOS zcube is universal (arm64 and x86_64)

*Decided 2026-11-13, by the slice (C3 slice 15).*

The owner allowed dropping Intel Macs if `x86_64-macos` cost real work. It cost none: `zcube`
compiles for `x86_64-macos` exactly as for `aarch64-macos` (`zig build mac-cross` builds both),
so the release keeps both and joins them with `lipo` into one universal binary, as Zigbox's
`mac-release` does for `zbx`. The cost is a second ReleaseSafe compile in `mac-release` and a
second Debug compile in `mac-cross`.

Through Homebrew only the arm64 half is installed: Zigbox's `zigbox` formula, which `zcube`
joins, has `depends_on arch: :arm64`. Dropping x86_64 later is one line, `mac_architectures` in
`build.zig`, and the `lipo` step's check in `src/mac_release.zig`.

Where: `docs/macos.md`, `build.zig` (`add_macos_steps`), `src/mac_release.zig`.
