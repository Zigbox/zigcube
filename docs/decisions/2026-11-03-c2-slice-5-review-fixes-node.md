# C2 slice 5 review fixes: /node-store/ is read tolerantly (list_all_tolerant: a malformed or newer record is skipped, counted, scores 0); the summary endpoint has its own body cap (summary_request_bytes_max, from the hex-encoded maximum) and ignores unknown fields; a refused summary write (ZC-E0504) is noted once and never stops replica work; decisions are v3 only with locality members; read_revision on a placement lets L1 skip rivals that changed after the read; C2 to C1 rollback is unsupported (docs/demos/c2.md)

*Decided 2026-11-03.*

C2 slice 5 review fixes: `/node-store/` is read tolerantly (`list_all_tolerant`: a malformed or newer record is skipped, counted, scores 0); the summary endpoint has its own body cap (`summary_request_bytes_max`, from the hex-encoded maximum) and ignores unknown fields; a refused summary write (ZC-E0504) is noted once and never stops replica work; decisions are v3 only with locality members; `read_revision` on a placement lets L1 skip rivals that changed after the read; C2 to C1 rollback is unsupported (`docs/demos/c2.md`). Trap: `zig build test -Dtest-filter=...` does not run the tests imported through `core.zig` or `tests.zig` (it passes with 0 tests); run the whole `zig build test`.

Where: not recorded (the source row had no Where cell)
