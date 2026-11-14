# A refused TLS handshake keeps its slot at most `tls_alert_flush_ms`

*Decided 2026-11-14 by the supervisor, on the B7 slice 4 reviews (A SHOULD 1, B NIT 1); made by
the slice 4 fix session.*

After a refused handshake the server stops sending and reads what the client still sends before
it closes (`linger_refused` in `src/server_http.zig`), so the kernel does not answer the
client's Finished with a reset that destroys the alert. That close used the slot state
`waiting`, which the watchdog ends only after `http_idle_timeout_ms` (10 s): an unauthenticated
client could keep a slot for up to the handshake timeout plus 10 s, and 97 of them held every
slot.

The close now has a slot state of its own, `lingering`, which the watchdog ends after
`tls_alert_flush_ms` (1 s, the bound the TLS client already gives an alert to leave). A refused
connection frees its slot within about 1 s plus a watchdog period (500 ms). No constant changed;
`tls_alert_flush_ms < tls_handshake_timeout_ms` is asserted in `constants.zig`.

Rejected: keeping the handshake state (`tls_handshake_timeout_ms`, 10 s), which bounds the slot
no better than the idle timeout did.

The test is `api_tls_test.zig`, "a refused handshake frees its slot within the alert flush";
with the state set back to `waiting` it fails. docs/mtls.md says the same.
