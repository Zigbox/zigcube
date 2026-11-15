# Zigcube's version numbers follow Zigbox's

*Decided 2026-11-14, by the owner (relayed by the supervisor).*

Zigcube's releases take Zigbox's version numbers. A milestone's release name, such as `b7`, stays as a
name, and the tag is `v<version>`.

| Zigcube release | Milestones | Version | Tag |
|-----------------|------------|---------|-----|
| b7 | B4–B7 | 0.5.1 | `v0.5.1` |
| — | C3–C5 | 0.6.0 | `v0.6.0` |
| — | C6–C8 | 0.7.0 | `v0.7.0` |

- **One source.** The version has one source, `.version` in `build.zig.zon`, which `build.zig`
  hands to the code as `build_options.version`. Through it, the version reaches:
  - `zcube version`;
  - `zcube-agent --version`;
  - the agent's `agent_version` in its node record;
  - the server's `GET /v1/status` (`server.version`), which the console shows.
- **Set on the bundle.** It was 0.0.0 until the B4–B7 bundle, which sets it to 0.5.1.
- **Placeholders stay.** Test fixtures, the console's in-browser simulation (`0.0.0-sim`) and the
  mock (`0.0.0-mock`) keep their placeholder versions.
- **The Zigbox pin.** Zigcube 0.5.1 should pin Zigbox v0.5.1 once that tag exists. Until then it
  pins aa4d64c (Zigbox 0.5.0's line).

Where: `build.zig.zon`, `docs/releases/b4-b7.md`.
