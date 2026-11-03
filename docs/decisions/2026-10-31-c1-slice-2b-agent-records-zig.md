# C1 slice 2b: agent_records.zig is the one record layer for FakeRuntime and the simulator (SimNode): the same code writes, scans and classifies containers over AgentState (DirState or SimState), so crash tests run production's write sequence

*Decided 2026-10-31.*

C1 slice 2b: `agent_records.zig` is the one record layer for `FakeRuntime` and the simulator (`SimNode`): the same code writes, scans and classifies containers over `AgentState` (`DirState` or `SimState`), so crash tests run production's write sequence. A spec the host cannot read is skipped like a damaged one; ZC-E0502 is for the directory itself.

Where: `src/agent_records.zig`, `docs/agent.md`
