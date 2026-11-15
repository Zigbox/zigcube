# zcube on macOS cannot use TLS yet; the port is required before 0.6.0

*Decided 2026-11-15, by the supervisor, on PR #264 (C3).*

CI's macOS job (`zig build test-cli` on macos-15-arm64, run 43759453373) crashed five tests once
C3 slice 15 (zcube builds for macOS) met B7's TLS (#258): the client's TLS path
(`api_tls_client.zig` → `tls_conn.zig` → `peer_stream.zig`) makes raw `std.os.linux` calls
(socket, connect, `sendto` with `MSG.NOSIGNAL`, `recvfrom`, `getsockopt`), and `trust_file.zig`'s
owner check calls `statx` and `geteuid`. On macOS they die with SIGSYS, so
`zcube --ca/--cert/--key` there would crash. `mac-cross` only compiles, so it could not catch it.

Ruling (option B of three):

- For #264, the five tests skip when `builtin.os.tag != .linux`, each with the comment
  "macOS TLS port, required before 0.6.0". Nothing else is skipped:
  - `peer_stream.zig`: "a connected socket has Nagle off", "a handshake with a failing random
    source is Entropy and sends nothing", "a message of several records crosses a handshaken stream
    both ways", "a message longer than the reader's buffer is TooBig, and a wrong node is refused";
  - `trust_file.zig`: "a refusal raises the caller's code and names its setting".
- No new ZC code: zcube on macOS does not refuse the TLS flags; it is ported instead.
- The port (option A) is required before 0.6.0 ships: `peer_stream`, `tls_conn`'s send and
  receive and `trust_file`'s owner check work on macOS through `std.c` behind `builtin.os.tag`
  (the pinned 0.17 `std.posix` no longer has socket, connect, sendto, recvfrom, getsockopt or
  fstat; macOS wants `SO_NOSIGPIPE` for `MSG.NOSIGNAL`, `fcntl` for `SOCK.NONBLOCK|CLOEXEC`, and
  `fstat` for `statx`), and the five skips are removed. A fresh session does it after #264 merges.
- Option C (taking the macOS job out of the gate) was rejected.

The cut is recorded in `docs/demos/c3.md`, "Cuts".
