# B1 ships without the 24-hour fleet run; B2 is a hardening release (owner, 2026-11-07)

B1 is released without the release rule's 24-hour fleet run on the shipping commit. Unblocking
Botpike now is worth more than a day's wait. Whatever the fleet finds afterwards is fixed in B2,
which is a hardening release.

Everything else in the rule still applies to B1. The shipping commit must have `demo-b1` green in
CI and pass `zig build check`, which runs `sim-cluster`, `sim-c1`, `sim-swarm` and the teeth runs
with fresh seeds. Two independent Opus reviews are required, with every MUST fixed or accepted in
writing. A retro follows the release.

This is a one-time exception for B1. It supersedes the 24-hour part of
docs/decisions/2026-11-04-release-gates.md for B1 only. The fleet keeps running on `main` after the
release, and every `sim-fleet` issue it files against B1 goes into B2's scope. B2 ships under the
full rule.
