# C1 slice 2b, first part: the agent's loop policy (agent_loop), its endpoint client over a Transport (agent_client) and its persisted-state interface (agent_state) are core; sim_net (drop, delay, duplicate, reorder, one-way partitions), sim_clock (offset, bounded drift, jumps forward only), sim_store (AckLossStore) and sim_node (containers that outlive the agent, files that a crash at a write point leaves half written) are core

*Decided 2026-10-30.*

C1 slice 2b, first part: the agent's loop policy (`agent_loop`), its endpoint client over a `Transport` (`agent_client`) and its persisted-state interface (`agent_state`) are core; `sim_net` (drop, delay, duplicate, reorder, one-way partitions), `sim_clock` (offset, bounded drift, jumps forward only), `sim_store` (`AckLossStore`) and `sim_node` (containers that outlive the agent, files that a crash at a write point leaves half written) are core. `SimNet` copies a reply before delivering a duplicate, because the handler's scratch arena is reused. `FakeRuntime` is not yet rewired onto `AgentState`; `DirState` is its shell implementation. Items 6-11 (`sim_cluster`, swarm, checkers, teeth, commands, docs) are the next session's.

Where: `docs/briefs/c1-2b.md`
