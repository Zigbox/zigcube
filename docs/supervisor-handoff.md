# Supervisor handoff

*Written 2026-10-30 by the supervisor session that shipped C0; updated the same day by the session that started C1. Update it when you hand off in turn: replace what changed, keep it short.*

## The role

The owner decides; the supervisor runs the work. You:

- write each slice's brief and start a **fresh implementer session** for it (`create_session`, a Sonnet model; a Haiku one for purely mechanical jobs, which AGENTS.md now requires (owner, 2026-10-30), and each brief names its slice's mechanical parts for the implementer to hand to Haiku);
- review every slice adversarially against `REVIEW.md`, `docs/STYLE.md`, `DIAGNOSTICS.md` and `docs/authority.md`, and start a fresh session for the fixes;
- open the PRs, watch CI (`subscribe_pr_activity`), and tell the owner when a PR is ready;
- merge your own green PRs that change only docs, the site or CI, when the owner has asked you to ship (they have, since C0); leave code PRs to the owner unless told otherwise;
- keep `README.md`, `site/index.html` and `site/architecture.html` in step with the status, and update the pages with the CI run link when a milestone ships;
- keep the live design doc (https://claude.ai/artifact/6D9js8mxSLYmfuZe3rQ26w, a Claude Doc) current when the owner decides something that changes it. Zigbox's `docs/SPEC.md` is a snapshot of it.

Zigbox (`Zigbox/zigbox`) is the sister project and ahead of us on process and diagnostics. Borrow from it ("borrow diags from Zigbox"); its `AGENTS.md`, `REVIEW.md` and `DIAGNOSTICS.md` are where new rules show up first. Check its `AGENTS.md` log when you start.

## Conventions that cost a round when missed

- Develop on the branch the session gives you; restart it from `origin/main` once its PR has merged. Never push to `main`, never force-push (fast-forward only).
- Commits are signed off (`git commit -s`) and end with the session's attribution lines. No model names in commits, PRs or code.
- CI runs on pull requests and `main` only. Documentation-only changes skip every job but `changes`; status-only commits carry `[skip ci]`, nothing else does.
- `merge_pull_request` needs the full 40-character head SHA.
- "Demonstrated" means `demo-cN` green in CI, with the run linked. `sim-cN` and `agent-smoke` are never called demos.
- Playwright here: the default headless shell is missing; launch Chromium with `executablePath` set to the binary under `/opt/pw-browsers/`.
- Implementer reports must carry the gates on the reported commit and a handoff note (`AGENTS.md`). A report without them goes back.
- Sessions you start are yours to archive, but only with the owner's OK. Scheduled tasks on this account that you did not create belong to other sessions; leave them alone.

## Where things stand

- **C0 · Loop: demonstrated** 2026-10-27 (run 40556942364), nine slices, PRs #4–#15.
- **Authority model, revision 3** (`docs/authority.md`) is approved and is what C1 is built to. The architecture page shows it; `docs/keys.md` points at it.
- **Process reset, 2026-10-30:** Zigbox's context discipline adopted (`AGENTS.md`), `REVIEW.md` and `docs/DECISIONS.md` added. `zig build check` does not exist yet.
- **The CI skip for documentation-only PRs works live:** on PR #22 (run 41071276402) only `changes` ran, and every code job was skipped.
- **C1 started 2026-10-30.** `docs/briefs/c1.md` is written; the fencing constants are the owner's (DECISIONS.md). Slice 1 (`zig build check`) merged in Zigbox/zigcube#23 after a clean supervisor review and a green CI run. Slice 2 (`docs/briefs/c1-2.md`, keys and writers) is with a fresh Sonnet implementer session. Zigbox's SPEC.md resync to live doc rev 86 is in Zigbox/zigbox#23, the owner's to merge.
- **Local mode settled (owner, 2026-10-30):** C1 builds `zcube local up` only; names and grants moved to C4; the demo keeps agents on one machine. The live doc is at rev 86 with this; Zigbox's `docs/SPEC.md` snapshot is still rev 78 and needs a resync (Zigbox's supervisor owns that file).

## The plan: C1 · Fleet

Slices are cut small so that each fits one implementer session under the context ceiling. Each has its own brief in `docs/briefs/c1-<n>.md`, written by the supervisor from `docs/briefs/c1.md`.

0. **Brief.** Done: `docs/briefs/c1.md`, which settled:
   - a replica that fits no node: held pending, with the shortfall in its decision;
   - the fencing constants (proposed: ttl 10 s, fence_stop 2 s, skew 1 %, fence_margin 3 s, `lost_grace_ms` 1 s) — **owner**;
   - a random part in server-assigned request IDs;
   - a watch fan-out benchmark and its bar;
   - the demo environment script in `demo/`, and the partition test HANDOFF asks for.
1. **Faster loop.** `zig build check`: every gate (build, test, tidy, errors-site-check, wasm-check, wasm-test, console-wasm, test-store on memory and SQLite, and Postgres when `ZCUBE_TEST_POSTGRES` is set), `sim-c0` with a fresh seed, and, as root, `zig build test` again as an ordinary user, as CI runs it. One last line: `check: PASS <commit>` or `check: FAIL ...`. Port it from Zigbox's `src/testing/check.zig`. A Haiku or Sonnet session; AGENTS.md's gate list then shrinks to this command.
2. **Keys and writers.** The C1 key layout (`/nodes` lease-bound, `/node-status`, `/assigned`, `/allocations`, `/audit/allocations`, `/observed` with tenure and assignment), the writer-role table enforced in the core (I4), the compare-set helpers. `docs/keys.md` rewritten from `authority.md`.
3. **Scheduler.** Fit and spread, the placement transaction with its full compare set, allocation accounting, pending with the shortfall.
4. **Node controller and auditor.** Lease expiry to `lost` after `lost_grace_ms`, rescheduling, the auditor's `ZC-B` findings blocking placement, `zcube repair allocations <node> --confirm` as a `repair_allocation` decision.
5. **sim-c1.** Invariants I1a–I7, the negative tests that must find I1b, I6 and I7 violations, the evidence acceptance test, native against WASM.
6. **Agent.** Registration with a lease, tenure-checked observed writes, self-fencing on `CLOCK_BOOTTIME` with `s` persisted, the partition test.
7. **Surfaces.** `zcube get nodes`, `get replicas -o wide`, `why node`, `repair`, `local up`; `docs/api.md` (`completeness` on `why`), the console.
8. **demo-c1.** The demo script from HANDOFF, three agents on one machine, as `zig build demo-c1` on SQLite and Postgres, in CI.

Then: README, site and architecture page updated with the run link; C1 marked demonstrated.

## Open with the owner

- C0's implementer sessions and the CI-skip session are archived (owner's OK, 2026-10-30), except slice 4 (`session_01Jc3KpBnbQjqTJsuVnLZ6uD`), whose archive the permission classifier refused; the owner archives it.
- Zigbox's `docs/SPEC.md`: resync to live doc rev 86 (C1 local mode, C4 local names and grants).
- Zigbox items, low priority: a separate diagnostics module (zigbox issue #8), a real code for `ZBX-E0501` and one for `lost`, container start time in `Runtime`.
- Before C7: a TLA+ model of fencing. Before a second server: a leader lease on `/leader/controllers`.
