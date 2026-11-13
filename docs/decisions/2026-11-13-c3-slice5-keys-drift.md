# C3 slice 5: the key layout as built, and where it departs from the brief

*Decided 2026-11-13, by the slice (C3 slice 5). The `/observed` version is pending the
supervisor's confirmation: the question was sent before the code was written, and no answer had
arrived when the slice was reported.*

## Drift check (before any code)

Checked against `main` at `f49041a` and the open branches `claude/b4-slice1`, `claude/b5-slice1`
and `claude/b6-slice1`:

- **Free:** `Service` and `Replica` version 4; the prefixes `/history/` and `/rollouts/`; the
  role `rollout_controller`; the codes ZC-E0125 to E0129, E0304 to E0306, W0304, W0305, E0516 and
  W0502. None of the three branches adds a key, a role or a code that collides.
- **Taken: `/observed` version 2.** C1 slice 6 already writes `"v": 2` (`tenure`, `assignment`).
  The brief's "`/observed` v2 adds `health`" cannot be version 2.

## Decisions

1. **`/observed` version 3 holds health** (`health` unknown|healthy|unhealthy, `health_failures`,
   `last_probe_exit`). This slice defines it and the reader accepts it; nothing writes it until
   slice 9. The alternative, leaving `/observed` alone until slice 9, was not taken: a server of
   this release must read what a slice-9 agent reports, so the reader goes first. Pending the
   supervisor's confirmation.
2. **A record is written at the oldest version that holds its members** (`records.encode`, which
   sets `v` for `Service`, `Replica` and `Observed`). A service with neither `health` nor a
   non-default `rollout` stays version 3, a replica without `health` stays version 3, an
   observation without health stays version 2. So a build before C3 still reads every record
   that uses nothing of C3, and no call site has to remember to set `v` (the `Assigned` rule of
   B1, made central). `src/testdata/b3_store.txt`, captured from `f49041a`, proves the old records
   read.
3. **A default rollout is stored as absent.** The owner's default applies to every service
   (2026-11-05); writing it out would make every new service version 4 for nothing.
4. **History is written only for a new generation.** Create, or a change of what a replica runs
   (image, `source`, command, `env`, `limits`, `health`). A scale, or a change of `rollout` alone,
   writes none: the generation did not change, and history is addressed by generation (owner,
   2026-11-05). A change of `rollout` alone does not bump the generation.
5. **History retention: deletes beyond the transaction's room are deferred.** The apply that
   writes the 17th record deletes the lowest generation in the same transaction. If a store ever
   held more (it cannot through the API), an apply deletes what fits in its transaction (16 ops,
   leaving room for its decision) and the next apply deletes more; the newest generations are
   never the ones dropped. Listing more than `history_scan_max` (64) history keys for one service
   is ZC-E0302, as every other bounded listing. A stored generation above the one being written
   is an earlier service's (a build before C3 deleted the service and left its history; a
   generation only grows within one service) and is deleted first.
6. **Deleting a service deletes its history first**, under the API role, in transactions that
   each expect the service at the revision the delete read. A conflict stops the delete with
   ZC-E0105 as before; history already deleted stays deleted (a rollback to it is ZC-E0128).
7. **Constants:** `history_generations_max = 16` (owner, 2026-11-05) and `history_scan_max = 64`
   (new, internal: a bound on one listing, not user-visible).
8. **W0502 (the probe timed out) is blamed on the user.** The brief gives no blame for it; the
   check's command and its `timeout_ms` are the user's. Review may change it before slice 9 uses
   it.
9. **The apply body does not take `health` or `rollout` until slice 11.** Slice 5 defines and
   stores them and validates them in `apply.Input` (ZC-E0125, E0126); the HTTP body and the
   service file gain them with the API and CLI slice, so nothing user-facing changes now.
10. **Validation bounds** (ZC-E0125, E0126): `health.command` 1 to 64 argv words, the first not
    empty; `interval_ms` > 0; 0 < `timeout_ms` <= `interval_ms`; thresholds >= 1;
    `max_surge` and `max_unavailable` <= `replicas_per_service_max`, not both 0 for `rolling`;
    `min_ready_ms` < `ready_timeout_ms` <= `progress_deadline_ms`. These are user-visible once
    slice 11 accepts the members; review them then.

Where: `docs/keys.md` (Versions, `/services` version 4, `/history`, `/rollouts`, `/observed`,
rollout decisions), `docs/authority.md` (the ninth role), `docs/api.md` and `docs/cli.md`
(planned endpoints and commands), `src/records.zig`, `src/history.zig`, `src/apply.zig`,
`src/writers.zig`.
