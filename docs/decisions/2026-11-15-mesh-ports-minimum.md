# The mesh port range holds at least `runtime_handles_max` ports

*Decided 2026-11-15, by the supervisor (option 1 of the question in
2026-11-15-c4-slice4-mesh-view.md, "Open: a spent range churns"); built in C4 slice 5.*

`zcube-agent` refuses, at start-up, a `--mesh-ports A-B` range (or `mesh_ports` in its ZON file)
that holds fewer than `runtime_handles_max` (512) ports, with ZC-E0505 (the agent's configuration
can't be used) and one cause line naming the range, its size and the minimum:

```
cause  the mesh port range 31000-31009 holds 10 ports, fewer than the minimum of 512
fix    give --mesh-ports a range of at least 512 ports, e.g. 30000-30999
```

Why: a replica the range has no port for fails to start with ZC-E0710 (blame: environment), and
the replica controller replaces a replica whose start failed through no fault of the user, so a
spent range churned: deleted and recreated in a tight loop (about 16,000 store transactions in 5
simulated seconds on one node). A node runs at most `runtime_handles_max` containers, so a range of
that many ports cannot be spent by the agent's own replicas. The default, 30000-30999, holds 1,000.

What it does not cover: a port of the range another program holds. Its replica still fails with
E0710 when the supervisor cannot bind it, and is replaced; the range is the operator's to keep
free. No backoff was added to the replica controller (option 2) and nothing was accepted as is
(option 3).

The existing code fits: E0505 already refuses a setting out of range, so no code was registered.
Its explanation now names the minimum; `swarm-smoke`, whose three agents shared one host with 100
ports each, gives each 512.

Where: `src/agent_config.zig` (`mesh_ports_of`), `zcube-agent --help`, docs/agent.md ("The mesh"),
docs/cli.md.
