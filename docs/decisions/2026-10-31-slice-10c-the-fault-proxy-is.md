# Slice 10c: the fault proxy is raw Linux sockets and one poll-free thread (std Io not used); a partition holds bytes and releases them on heal; the history checker takes the log read after healing, and a write's outcome (acked, failed, unknown) is settled against it by value tokens, so a lost acknowledgement needs no guess.

*Decided 2026-10-31.*

Slice 10c: the fault proxy is raw Linux sockets and one poll-free thread (std `Io` not used); a partition holds bytes and releases them on heal; the history checker takes the log read after healing, and a write's outcome (acked, failed, unknown) is settled against it by value tokens, so a lost acknowledgement needs no guess.

Where: `src/testing/fault_proxy.zig`, `src/testing/history.zig`
