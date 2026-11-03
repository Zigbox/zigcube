# C1 slice 2b part G

*Decided 2026-10-31.*

C1 slice 2b part G. Teeth: the agent's test-only fault is `agent.fault_ignore_stop` (it ignores every stop order), a constant read from the root file's `agent_teeth_ignore_stop` declaration, so no shipped or test root can enable it; `sim_teeth_main.zig` is the one root that does and only `zig build sim-teeth` (and `sim-teeth-exe`) compile it. `sim-teeth` runs seeds 1 to 10 at 100 operations and fails unless one fails (seed 1 does; 20 of 20 did). Debug build: 7 s against 50 s for ReleaseSafe. `zcube_agent.zig` asserts it off at compile time.

Where: `src/agent.zig`, `src/sim_teeth_main.zig`, `build.zig`
