# Botpike's first nodes are generic Linux VMs, not Fly Machines

*Decided 2026-11-12, by the owner (hosting); recorded by the supervisor.*

This amends O5 of `docs/briefs/botpike-first-customer.md` ("Where nodes run"). That O5 is not the
same as C2's O5 in `2026-11-05-o5-registry-first.md`.

Botpike no longer has a design goal of running on Fly. Its first nodes are generic Linux VMs,
most likely on Azure first, because of its startup credits. Botpike records this as P161
(Botpike/app#161). The input came from Zigcube #228 and Zigbox #119.

What changes:

- **The O5 check.** O5 asked for `zbx doctor` on a Fly Machine before the B3 demo was planned. It
  becomes `zbx doctor` on the first VM size Botpike picks. That size needs unprivileged user
  namespaces, cgroup v2 with user delegation, and `uidmap`, as before.
- **Size choice.** Botpike should prefer a size that exposes nested virtualisation (`/dev/kvm` in
  the guest). Many Azure sizes do. Zigbox S1 (`--isolation vm`) could then run on the first
  nodes. Until S1, the input's rule stands: each tenant gets nodes of its own.
- **Demos.** Nothing changes. B3 to B5 already run on generic Ubuntu 24.04 guests with KVM in CI.

Where: `docs/briefs/botpike-first-customer.md` (O5, the input as written), this file.
