# ZC-E0821: a failed secure random source is an error, never a fallback

Status: **adopted** (B2 slice 6, 2026-11-07; supervisor approved the new code). The owner may veto.

RB-N9: key, nonce, session-id and CA-seed material was drawn with `std.Io.random`, which does not
promise the operating system's secure source. All such paths now go through `src/secure_random.zig`,
which calls `randomSecure` and, when that fails, raises **ZC-E0821** (blame: environment) and
returns an error. No path falls back to the weaker generator.

- Why a code: the failure is real (a seccomp profile that blocks `getrandom`) and the operator's
  fix is specific; no existing code fits. Alternative was cutting RB-N9 from the slice.
- Touched: the TLS client's random, session id and key-share secret (`tls_conn.zig`), the server CA
  and agent peer seeds, and the peer stream's seed (`peer_stream.zig`, `peer_server.zig`).
- Tests inject `std.Io.failing` and expect E0821 and no output bytes.
