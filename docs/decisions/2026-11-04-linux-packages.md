# Linux packages: deb and rpm in C3 (owner, 2026-11-04)

*Decided 2026-11-04, by the owner.*

C3 ships Zigcube as `.deb` and `.rpm` packages (`zigcube`, `zigcube-server`, `zigcube-agent`) from
the signed apt and dnf repository Zigbox's next release sets up: "There's no reason not to have an
RPM if we have a DEB." Packages are built in Zig, signed on the owner's machine, and leave units
disabled on install. `zcube-server` links system SQLite and libpq, so its packages are per
distribution release. Detail: `docs/briefs/c3-linux-packages.md`; Zigbox's side is Zigbox
`docs/briefs/linux-packages.md` and its decision of the same date.
