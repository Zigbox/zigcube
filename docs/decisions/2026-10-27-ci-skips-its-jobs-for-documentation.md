# CI skips its jobs for documentation-only changes; .zig, .zon and .sh files are code anywhere, and a guard that cannot decide runs everything.

*Decided 2026-10-27.*

CI skips its jobs for documentation-only changes; `.zig`, `.zon` and `.sh` files are code anywhere, and a guard that cannot decide runs everything.

Where: `.github/workflows/ci.yml`
