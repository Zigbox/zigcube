# Slice 10c review fixes: the checker is strict where the model is narrow (a register write puts only its own key and its failure puts are audit keys; value tokens are unique across the history; a watch is judged only inside the log's range; all of these are bad_history, never guessed at) and checks that revisions follow real time across keys (revision_order)

*Decided 2026-10-31.*

Slice 10c review fixes: the checker is strict where the model is narrow (a register write puts only its own key and its failure puts are audit keys; value tokens are unique across the history; a watch is judged only inside the log's range; all of these are `bad_history`, never guessed at) and checks that revisions follow real time across keys (`revision_order`). The proxy's `heal` resets connections the black hole swallowed (they have no upstream to resume), `cut_after(dir, 0)` is one shot, the upstream connect gives up after 1 s, and latency throttles a lane to one 16 KiB chunk per period (documented, not fixed).

Where: `src/testing/fault_proxy.zig`, `src/testing/history.zig`
