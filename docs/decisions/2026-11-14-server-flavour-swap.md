# The server flavours keep their own server.zon

*Decided 2026-11-14 by the supervisor, from the packaging slice 1 review (SHOULD 6).*

**Decision.** Each server flavour (`zigcube-server-sqlite`, `zigcube-server-postgres`) keeps its own
`/etc/zigcube/server.zon` conffile. When the flavour is swapped, the administrator's file is kept,
and `docs/releases/packaging.md` says to check `.store` after a swap.

**Evidence.** The install test (`.github/packages-install.sh`) ran on Debian 12, Ubuntu 24.04,
Fedora 42 and Rocky 9. In each, the test edited `server.zon` and then swapped the SQLite flavour
for the Postgres one. Afterwards the file still said
`.store = "sqlite:/var/lib/zigcube/server.db"`, and the Postgres server refused that store with
ZC-E0217 until it was rewritten. The swap also removes `zigbox-dev`, which depends on the SQLite
flavour. On dnf, the swap needs `--setopt=clean_requirements_on_remove=False` to keep the agent.

**Rejected: one flavour-neutral server.zon with no `.store` line.** It would make swaps seamless.
But the server's default store with no `.store` line is memory, so the Postgres flavour would need
a different compiled-in default, which changes a user-visible default. Swaps are rare, and a wrong
`.store` fails loudly with ZC-E0217.
