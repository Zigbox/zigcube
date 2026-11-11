# B3 slice 4 pins a Zigbox `main` commit until the M8b release

*Decided 2026-11-11, by the owner.*

B3 slice 4 (the real runtime and the hostile tests, `demo-b3`) needs Zigbox's M8b listener
handoff. The B3 brief says slice 4 starts after M8b is in a Zigbox release and the pin moves to
it. Cutting that release (the extended fuzz run and two release reviews) takes most of a day, and
slice 4 would wait for all of it.

Instead, slice 4 pins `build.zig.zon` to the Zigbox `main` commit that merges M8b
(Zigbox/zigbox#89), and starts as soon as that commit exists. The Zigbox release is cut beside it.
When the tag lands, the pin moves to the tag (a one-line change, with its new `.hash`).

- B3 does not ship, and `b3` is not tagged, until the pin names a Zigbox release tag.
- The fleet soak may start on the `main`-commit pin. If the move to the tag changes anything
  but the pin line and its hash (the release's fixes touch code Zigcube links), the soak restarts.
- The pin before this was Zigbox 0.3.1 (ba3c444). This move also brings in 0.4.0's contents
  (M8), which B5 needs.

Where: `docs/briefs/b3.md` (Slices, 4), `build.zig.zon`.
