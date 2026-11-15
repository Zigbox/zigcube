# sim-cluster's request floor does not judge a fault phase shorter than one lost call (10 s)

*Decided 2026-11-15, by the slice (#56 regression on the b3 candidate 00f35c1).*

`request_floor_met` (`src/sim_cluster.zig`) returns true when the fault phase lasted less than
`request_floor_fault_ms_min`, which is the agent's I/O timeout (`constants.agent_io_timeout_ms`,
10,000 ms of virtual time): what one lost call or cut link costs the agent, and what `sim_net`
charges for it. Above it the floors are unchanged: one
request per operation with 120 s of summed uptime, half a request per operation below that.

Why: operations are not time. Seed 2846914288 (35 operations, `--strong`, 2 nodes, ttl 8,082,
heal at 42) drew 3 `advance`s, so its whole fault phase was 8,249 ms. Requests reached 17 in the
first 5.3 s; then one node was cut and the other's call was lost, and a lost call costs the agent
10 s, longer than the window left. 17 of 35 is half a request short of the floor; the heal phase
was healthy (534 agent steps, 7,057 requests, every invariant held). A probe of 600 short runs
(seeds 1 to 600, 1 to 40 operations, 1 to 3 nodes, `--strong`) found one more such miss, seed 207
(10 operations, 6.5 s, 2 delivered); every ratio under 0.93 was in a window under 10 s, and at least
0.93 requests per operation in every window of 10 s or more (1.08 from 20 s, 1.43 from 30 s).

A cluster that is down most of the time still fails from 10 s up; below it the window holds less
than one lost call, and the floor measured the draw, not the cluster. The unit test "the request
floor catches a cluster cut off for a fault phase long enough to judge" cuts a node's link both ways
for twice the minimum and needs the floor to fail; with the floor switched off, it and both other
floor tests fail.

Where: `src/sim_cluster.zig` (`request_floor_met`, its tests), `build.zig` (`c1_regressions`).
