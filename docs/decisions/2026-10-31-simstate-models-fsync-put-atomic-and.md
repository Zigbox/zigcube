# SimState models fsync: put_atomic and remove are durable once they return, an append is not, and a host crash can drop the unsynced tail of any file

*Decided 2026-10-31.*

`SimState` models fsync: `put_atomic` and `remove` are durable once they return, an `append` is not, and a host crash can drop the unsynced tail of any file. `arm_crash` crashes at a write point and `crash_now` between calls (step boundaries).

Where: `src/agent_state.zig`, `docs/core.md`
