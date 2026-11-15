# sim-c4: what changes in the simulated worlds

Date: 2026-11-15. C4 slice 5.

- **`auto` turns the mesh on.** The brief says `--mesh` is on under `--c4` and `auto`. A drawn
  run (`<ops>` = `auto`) now also runs the mesh: agents give replicas mesh ports and rules and
  the supervisors' connections are modelled (`src/sim_mesh_conns.zig`). The connection model
  draws from a generator of its own (the seed xor a constant), so the cluster's own draws are
  the same, but the agents' steps (mesh fetches, rule updates) and the grants in each apply
  differ, so an `auto` world is not the world it was before slice 5. A replay line prints
  ` --mesh` (or ` --c4`), so a line written now replays; a line written before slice 5 without
  `--mesh` runs the old world, as before.
- **A `mesh` fault profile, weight 2.** The brief asks for one (supervisor partitions, slow
  agents, grant churn). Appending it to `sim_shape.ClusterProfile` with weight 2 changes the
  total weight from 11 to 13, so `--profile=auto` draws other profiles for some seeds than it
  did. Replay lines name the drawn profile, so they are unaffected.
- **Containers warm up in the mesh world.** A started container reports `starting` (its
  supervisor up, the command not yet) for 1 to 4 s, drawn per node from the seed
  (`SimNode.warmup_ms`); without it the simulated runtime reports `running` at once, no view ever
  holds a replica with an endpoint that is not ready, and M4's tooth (`mesh_route_unready`) can
  never fail. The controllers see the same `starting` that real nodes report.
- **Direct dials.** One request in four skips the source's listeners and dials a peer's mesh port
  on a drawn port. Listeners exist only for granted destinations, so without these M1's tooth
  (`mesh_no_dst_check`) failed on one seed of ten; with them, on every seed. An accepted dial is
  counted, not kept as a connection: the source's supervisor never held it, so M2 does not apply.
- **Worlds without `--mesh` are unchanged:** the hooks are unset, no grant is drawn and the model
  is never ticked.
- C4 slice 3's teeth (M3, M3r, M6) stay in `sim-c1-teeth` and its canaries; sim-c4 adds the
  three of slice 5 under the fleet kind `sim-c4`.
