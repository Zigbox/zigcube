# Eight connection slots are kept for the loopback listener

*Decided 2026-11-14, by the supervisor, on the B7 slice 3 review (SHOULD, "shared connection
slots"); proposed by the fix session.*

`zcube-server` serves `http_connections_max` (96) connections across both listeners. When both
`--listen` (TLS) and `--insecure-listen` (loopback) run, TLS clients take at most 88 of them
(`http_loopback_reserved` = 8 kept back); the loopback listener may take any free slot and takes
the reserved ones first. With `--listen` alone, TLS gets all 96. The total, the 50 long-poll
holds (`http_holds_max`, counted inside the TLS share) and the Postgres `max_connections` advice
(80 or more) are unchanged.

Why: one pool let a TLS client that opens connections, or stalls in its handshakes, fill every
slot and lock out the loopback listener that the harnesses, `zcube local` and an operator on the
server host use. A TLS connection past its share is closed without a reply, as before.

Where: `src/constants.zig` (`http_loopback_reserved`), `src/server_http.zig` (`take_slot`,
`Shared.tls_slots`), `src/server.zig` (`open_listeners`, `accept_loop`); the test is
`api_tls_test.zig`, "TLS clients fill at most their slots"; AGENTS.md "Server limits",
docs/mtls.md.
