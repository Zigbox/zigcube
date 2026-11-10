# Botpike O5: Fly Machines are not planned as Zigbox nodes

*Decided 2026-11-10, by the owner ("Fly machines are Firecrackers, so the odds are, they won't run
Zigbox"); recorded by the supervisor.*

O5 in `docs/briefs/botpike-first-customer.md` asked whether Botpike's runs could go on Fly
Machines. Zigbox needs unprivileged user namespaces, cgroup v2 with user delegation and `uidmap`
(`zbx doctor`), which a Firecracker guest is not expected to give.

- Nothing in B3 to B7 is planned around Fly Machines. `demo-b3` runs in the demo VMs
  (`demo_c2_vms.zig`'s rig, Ubuntu 24.04), as `docs/briefs/b3.md` slice 4 says.
- Where Botpike's nodes run is still open: a host that passes `zbx doctor`. If someone runs
  `zbx doctor` on a Fly Machine and it passes, this decision is superseded by a new file.
