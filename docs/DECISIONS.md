# Decisions

Lasting decisions, newest first, each with where its reasoning lives. Implementers add a line here when a slice decides something the next one must build on; the supervisor adds the owner's decisions. A decision is changed by a new line that says what it replaces, never by editing an old one.

| Date | Decision | Where |
| --- | --- | --- |
| 2026-10-30 | Fencing constants (owner): `ttl` 10 s, `fence_stop_ms` 2 s, `skew` 1 %, `fence_margin` 3 s, `lost_grace_ms` 1 s. | `docs/briefs/c1.md` |
| 2026-10-30 | Agent context discipline adopted from Zigbox: one session per slice, handoff notes, a 250K-token / 60-turn ceiling, fixes by fresh sessions. `REVIEW.md` is the self-review checklist; `zig build check` becomes the one gate command (C1's first slice). | `AGENTS.md`, `REVIEW.md` |
| 2026-10-27 | CI skips its jobs for documentation-only changes; `.zig`, `.zon` and `.sh` files are code anywhere, and a guard that cannot decide runs everything. | `.github/workflows/ci.yml` |
| 2026-10-27 | C4 workload identity binds service, image digest and placement epoch; C7 enforces the epoch for stateful services and moves a stateful replica only with a fencing proof. | `docs/authority.md`, live design doc |
| 2026-10-27 | Authority model, revision 3 (owner-approved): three state classes; one writer role per key prefix; the read-set rule; `/allocations/<node>` as the authoritative aggregate, rebuilt and checked by an auditor that never repairs; `/node-status` in the placement compare set; tenure fencing of observed writes; agent self-fencing on `CLOCK_BOOTTIME`; immutable decisions with cited evidence and separate summaries; `why` is complete or truncated with a reason; sim-c1 invariants I1a–I7. | `docs/authority.md` |
| 2026-10-27 | C0 demonstrated: `demo-c0` green on SQLite and Postgres. | CI run 40556942364 |
| 2026-10-26 | Provisional answers: node capacity declared in agent config; long-poll HTTP watch; decision retention 200 per subject, 7 days, 24 h after deletion (refined by the authority model's roots). | `HANDOFF.md`, `docs/contracts-review.md` §5 |
| 2026-10-26 | Runtime: a supervisor process per container (the owner's exception to "no daemon"); re-adoption is `list`. | `docs/contracts-review.md`, `docs/agent.md` |
| 2026-10-26 | Zigbox's diagnostics are Zigcube's, through the pinned `zigbox` package; `ZC-` codes are registered in `src/diag.zig`. | `DIAGNOSTICS.md`, `docs/diagnostics-plan.md` |
