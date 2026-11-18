# `zigcube.sh server` waits for the listener, not only the CA file

*Decided 2026-11-18, by the slice (C5 slice 2).*

`ops/jepsen/zigcube.sh server` returned as soon as the server's CA certificate appeared. The
server writes it before it opens its listener (the browser CA is made in between), so a client
run right after `server` could be refused. `test-recipe.sh` did exactly that and failed about one
run in three under `zig build test`'s load on C5 slice 2's branch (passed alone). The script now
also waits, up to the same 30 s, until the `--listen` port accepts a connection. The probe
connection ends before its TLS handshake, which the server logs once as ZC-E0816.

Where: `ops/jepsen/zigcube.sh`, `cmd_server`.
