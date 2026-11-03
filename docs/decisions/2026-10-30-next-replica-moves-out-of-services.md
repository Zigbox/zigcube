# next_replica moves out of /services/<name> to a key of its own, written only by the replica controller, in C1 slice 3 (owner)

*Decided 2026-10-30.*

`next_replica` moves out of `/services/<name>` to a key of its own, written only by the replica controller, in C1 slice 3 (owner). `/services/` is then the API's alone and `writers.zig` loses the `api_with_counter` exception. Replaces the interim exception in the slice 2 row below.

Where: `src/writers.zig`, `docs/authority.md` §2
