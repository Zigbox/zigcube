# C3 slice 11: the API, CLI and console for rollouts and history

*Decided 2026-11-14, by the slice (C3 slice 11), with the supervisor on item 1 (option A).*

Slice 11 serves what slices 5 and 6 defined: `GET /v1/services/<name>/history`,
`GET .../rollout`, `POST .../rollout/pause|resume`, `health` and `rollout` in the apply body,
`zcube history`, `zcube rollout status|pause|resume`, and the console's Rollout and Generations
cards. Rollback is slice 8's. It is built against the records of slices 5 and 6 and
`rollout_plan.zig`, never slice 7's controller.

1. **Pause and resume are a rollout-controller transaction (option A, supervisor 2026-11-14).**
   `/rollouts/` has one writer (authority.md I4). The API process therefore does not write the
   record as the API: `src/rollout_steer.zig` runs a small transaction in the
   `rollout_controller` role. It reads the service and the rollout, applies
   `rollout_plan.pause_rollout` or `resume_rollout`, and writes the record and a decision
   (`rollout_pause` or `rollout_resume`, actor `rollout-controller`, citing `applied_by` and
   the request id), comparing on both keys' `mod_revision`. A failed compare is retried, up to
   `rollout_steer.attempts_max` (3) attempts, then answers ZC-E0105, as any contended write does.
2. **R4: a pause cannot be overtaken by a controller pass.** A pause sets `budget` to zero in
   the same write as `phase: paused`. Slice 7's controller computes a budget from a read and
   writes it with a compare on the rollout's `mod_revision`. A pause committed between that read
   and that write moves the revision, so the controller's write fails and its next pass reads
   `paused`. So no budget computed before a pause is ever committed after it, and the replica
   controller never sees a nonzero budget on a paused rollout. **Two seams for slice 7:**
   (a) the rollout controller's write of `/rollouts/<name>` must keep that compare on the
   record's `mod_revision`; (b) when `src/replica_controller.zig` reads `/rollouts/<name>` to
   obey its budget, its own write (the replicas it starts or retires) must also compare on the
   `/rollouts/` key's `mod_revision` as read. Without (b), a replica controller pass that read
   `budget.start = 1` before a pause commits its start after it: a pause followed by a start,
   which breaks R4. Slice 7's tests should include "a pause lands between the read and the
   write" for both controllers (slice 11's tests cover the pause side: `rollout_steer.zig`'s
   conflict and retry tests, with `Race`).
3. **The record's new members** (`docs/keys.md`): `reason` (`apply` or `rollback`),
   `evidence_from_ms`, `paused_at_ms`, `paused_by` (`user` or `failure`). They are all
   optional, so slice 5's records still read: an absent `reason` comes from the phase, and a
   `paused` record without `paused_by` reads as paused by a failure. A resume restarts the
   evidence window and moves the progress deadline later by the length of the pause.
4. **`GET .../rollout` answers 200 with `rollout: null`** when there is none, including one that
   belongs to an earlier service of the same name (`records.rollout_of`). The service exists,
   and "no rollout" is one of its states. An unknown service is 404 ZC-E0101.
5. **ZC-E0129 is 409.** `status_for` maps it with E0131 (a state conflict, not a bad request).
   That is a status mapping for an existing code, not a new code. A pause of a paused rollout,
   or a resume of a running one, succeeds with `action: none` and `change: no change`
   (docs/api.md has the reply).
6. **History shows the reason, not a replica count.** A history record is a generation's spec,
   and replicas are not part of it. `zcube history` and the console show `apply` or
   `rollback of N`, who applied the generation, and the request id. There is no free-text
   "why": the service record has none to copy.
7. **The console stays read-only.** Pause and resume are commands to copy (`howTo`), not
   buttons, as every other change in the console is (docs/console.md, "Interaction rules").
8. **The mock does not roll out by itself.** `?mock=c3` writes a rollout record by hand (in the
   shape of slice 7's controller) and pauses it through `steerRollout`, which mirrors
   `rollout_steer`. The mock's own replica controller still replaces replicas at once.
9. **`-o wide` is not taken** by `rollout` or `history`: there is nothing wider to show.
10. **Cut: `zcube get service` does not show the rollout, and `zcube why` does not render the
    rollout chain** (brief item 11). Showing a rollout in `get service` correctly needs the
    record's incarnation check (`records.rollout_of`, `service_created` against the service's
    `create_revision`), which the CLI's listings (`cli_data.Kv`) do not carry, and a new column
    that `demo-c0` and `demo-c1` read past; `zcube why` has no rollout decisions to render until
    slice 7's controller writes them. Both move to **slice 8** (rollback), which already adds
    `zcube rollback` and runs after slice 7, so its tests can render real `rollout_*` and
    `rollback` decisions; demo-c3 (slice 12) asserts both. `zcube rollout status <name>` is
    what shows a rollout until then. Recorded in `docs/demos/c3.md`, "Cuts".
11. **A new `zcube` against a server before slice 11.** Such a server answers the new routes
    with 404 ZC-E0101 "serves nothing", and refuses an apply body with `health` or `rollout`. The
    CLI recognises the 404 on `rollout` and `history` and says the server does not serve the
    command (ZC-E0101 with that cause; no new code). The order is in `docs/cli.md`: upgrade the
    server first.
