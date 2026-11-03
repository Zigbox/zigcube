# AgentState.remove of a name ending in / removes an empty directory, durably; SimState has no directories, so there it is Absent and passes no write point.

*Decided 2026-10-31.*

`AgentState.remove` of a name ending in `/` removes an empty directory, durably; `SimState` has no directories, so there it is `Absent` and passes no write point.

Where: `src/agent_state.zig`
