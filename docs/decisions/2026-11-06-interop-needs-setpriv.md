# The interop harness needs setpriv, and the JVM requires close_notify
*Decided 2026-11-06, by the slice 8 implementer, on the review of #107 (owner's decisions relayed by the supervisor).*

Adds to [2026-11-05-interop-tools-are-test-only.md](2026-11-05-interop-tools-are-test-only.md), which stays as it is.

1. **`setpriv` (util-linux) is a third required tool** of `zig build mtls-interop`, beside `openssl` and JDK 21. The harness starts every stock server under `setpriv --pdeathsig KILL` so the kernel ends it with the harness. Like the others it is a test tool: no shipped binary uses it. The harness checks for it first and fails, not skips, with a line naming it.
2. **The JVM server runs with `-Dcom.sun.net.ssl.requireCloseNotify=true`.** Without it the JDK reports a clean end on a TCP close with no `close_notify`, so a client that dropped the connection would pass `close_clean`. Proved by mutation: closing the socket before `close_clean` in the two Java scenarios fails both with "the server never saw our close_notify".

Where: `docs/mtls.md`, AGENTS.md (Commands), `src/mtls_interop.zig`.
