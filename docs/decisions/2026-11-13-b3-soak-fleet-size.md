# The b3 soak runs on a rescaled fleet host

Date: 2026-11-13. Decided by: the owner (option C), recorded by the supervisor.

Supersedes one line of `2026-11-13-b3-soak-measured-in-seeds.md`: the fleet size
("6 sim-cluster, 6 sim-c1, 1 sim-swarm on 14 slots, about 4 hours"). That decision
assumed a 14-slot host; the fleet host is a Hetzner CPX32 (4 vCPU, 8 GB). Everything
else in it stands: the soak commit, the freeze, the seed targets and the gate.

## Decision

- For the soak, the owner rescales the host to a CPX51 (16 vCPU, 32 GB), "CPU and RAM
  only", so the disk keeps its size and the host can scale back.
- `/etc/sim-fleet/fleet.env`: `SIM_FLEET_WORKERS_CLUSTER=7`, `SIM_FLEET_WORKERS_C1=7`,
  `SIM_FLEET_WORKERS_SWARM=0`. sim-swarm has no b3 target, so it pauses for the soak.
- The unit's `MemoryMax` is raised to `30G` (a drop-in), then `systemctl daemon-reload`
  and `systemctl restart sim-fleet`.
- Expected time to 20,900 sim-cluster and 20,900 sim-c1 seeds: about 3.5 hours.
- After the b3 tag: scale back to a CPX32, `fleet.env` back to 1/1/1, `MemoryMax=7G`.

## Why

Fastest of the three options (one host at 2/2/0 took about 12 hours; two hosts about 6
hours with counts summed by hand), one tracker, and the cost is under €1.
