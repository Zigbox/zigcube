# 2026-11-13: B4 slice 3, fixes after review

Two adversarial reviews of `claude/b4-slice3` at 82e48c8 (A: merge after SHOULDs; B: merge
after MUSTs). This file records what the fix session changed, the supervisor's rulings, and the
follow-ups that B4 keeps open. The slice's own decisions are in
`2026-11-13-b4-slice3-sim-certs.md`.

## Changed

- **Canary ranges measured (MUST, both).** The three teeth of the slice and the two this fix adds
  were each run over 240 seeds or more, drawn operations and `--profile=auto` with `--c1`, as the
  fleet's canary runs them, and their `canary_seeds` in `build.zig` are sized by the rule of
  `ops/sim-fleet/README.md` (a miss by chance below 1e-9 per run at an assumed floor under the
  measured rate). The table there has their rows. The numbers are below, under "Measurements".
- **R4 names the image (SHOULD 1).** `sim_certs.issued_problem` now compares the issued subject's
  `image_digest` with the digest the job pins, read by the checker's own parse of `b3:<hex>` (not
  `job_cert.image_digest`, so the rule is not judged by itself). And a forged ask that gets a
  certificate fails R4 ("a forged ask got a certificate") even when no clause names why: every
  counted forgery names another node, an earlier epoch or another image. A new tooth,
  `job_cert_image`, switches off `decide`'s image compare; the forged `other_image` asks then get
  certificates and R4's image clause must catch it.
- **R7: connections close within `relay_cancel_ms_max` of a stop (SHOULD 2).** `SimRuntime` keeps
  the time a container was told to stop (`stop_requested_ms`, set when a slow container enters
  `.stopping`; a container that ends at once closes its connections in `end`). `stop_conns_problem`
  fails a container still in its grace with connections open past the bound, and a sticky flag
  (`conns_late`) fails one that ended with connections still open past it, so a stop and its end
  between two checks cannot hide the late close. Judged from `safety()`. The tooth
  `relay_stop_leak` skips the close in the `.stopping` transition. The bound is the brief's
  `relay_cancel_ms_max = 2 * relay_poll_ms` (100 ms), defined in `sim_runtime.zig` until slice 2
  brings it to `constants.zig`; on that merge, use the constant and delete the local one.
  No container of the cluster simulation ever entered `.stopping` (`random_fault` never draws
  `slow_stop`), so the tooth could not fail: a first 240-seed sweep caught nothing. Half the
  relayed runs now take their grace when told to stop (`SimRuntime`'s `stop_takes_grace`, chosen
  by a hash of the job's name when their certificate is issued, no draw): a `stop` puts them in
  `.stopping` for the run's grace (under 2 s), and R7 has something to judge. A TERM signal still
  ends them at once, unlike `slow_stop`. The first try made them ignore TERM (`slow_stop`): the
  fence's TERM then did nothing, and a node that learned late that its lease was gone ran such a
  run up to `fence_stop_ms` past it; 3 of 240 `--strong --c1` seeds (27, 90, 94) failed I1b's
  "self-fencing failed" bound (lost grace + 2 checks, 3 s). That bound and the fence's KILL delay
  are not this slice's to change, so TERM keeps its old effect. This changes the `strong` world
  only, and only for relayed runs.
- **Docs (NITs).** `docs/core.md` and the header of `sim_certs.zig` say when each check is judged:
  R4 and R5 once, at issue; R6 at every committed revision under `--c1` and from `safety()` (every
  `check_interval_ms` and after every operation) with or without it; R7 from `safety()`.

## Rulings (supervisor, 2026-11-13)

- **R6 reads "reported" as reported by the node.** R6 counts only the node's own `stopped` record
  of the run, never a terminal status the controller wrote: a cut-off node's container may outlive
  the controller's ending, J1 bounds that overlap, and the node has not yet been told. Accepted by
  the supervisor on that reasoning (the slice's decision file, "R6 counts only the node's own
  `stopped` report").
- **R6 and R7 test the simulation, not slice 2's relay.** They test the simulated runtime's
  connections (counters in `sim_runtime.zig`) and the agent's ordering of stop, end and report.
  They do not test `relay_pump.zig` or any socket: slice 2's tests and `demo-b4` do that.
- **No clock-skew dimension in this slice** (review B, SHOULD 4). See the follow-ups.

## Follow-ups (B4 keeps these open)

1. **Issuance through the server's handler** (review B, SHOULD 3). `sim_certs.issue` reads the
   records itself and calls `job_cert.decide`. The server's issuance handler is slice 2's and is
   not on this branch, so there is nothing pure to route through yet.
   *Acceptance:* after slice 2 merges, the model's honest asks go through the same core function
   the server's `/v1/.../cert` handler calls (records read, rule applied, refusal mapped to
   ZC-E0706), as a call the simulated network can cut, drop or delay; forged asks stay raw calls
   to that function; `sim-c1-teeth-job_cert_stale` and `_image` still catch.
2. **The realistic stale epoch** (review B, SHOULD 3). Today a stale epoch reaches the issuer only
   by a forged ask. The real case: an old run's supervisor still runs behind a cut link while its
   job's name is deleted and reused on the same node, and asks for the new run's certificate with
   the old epoch. The reuse world (`sim-c1-reuse`) makes no relayed jobs, and making them there
   changes that world's draws and its pinned seeds, which is more than a fix session should move.
   *Acceptance:* the reuse world makes relayed jobs; a run counts the asks an earlier
   incarnation's supervisor made for a reused name; over the reuse world's 60 seeds that count is
   above zero; `job_cert_stale` is caught there by honest asks alone (forgeries off).
3. **Node and server clocks** (review B, SHOULD 4; supervisor ruling: not in this slice). The
   issuer's `now` and R5's bound both read the asking node's clock, so the model cannot see the
   two ways a real skew between node and server fails:
   - a node whose wall clock is behind the server's by more than deadline + grace + slack is
     refused every certificate (`lifetime`): the run starts and cannot connect, though it holds
     its claim;
   - a node whose clock is ahead has its start taken as the server's now (`decide`'s `@min`), so
     the certificate's `not_after` is later than start + deadline + grace + slack on the server's
     clock by up to the skew: R5's bound, read on the server's clock, is exceeded.
   *Acceptance:* the issuer reads a simulated server clock with its own offset; skew is drawn up
   to the cluster's skew bound; R5 is judged on the server's clock with the skew term the owner
   approves, and the refusal rate for `lifetime` is reported; a tooth that draws skew past the
   bound must fail R5. The NTP dependence (slice decision, "The issuer's now") goes to the owner
   with it.

4. **A TERM-ignoring container and a late fence** (found by this fix session, not a review
   item). The cluster simulation never draws `slow_stop` (`random_fault` has no such kind), so no
   simulated container ignores the fence's TERM. When relayed runs ignored it, seeds 27, 90 and 94
   (240 seeds, drawn operations, `--profile=auto`, `--c1 --strong`) failed I1b's "self-fencing
   failed": on seed 90, node1's `/nodes/` key had been gone 3,076 ms with `jb-10-job` still
   running, TERM ignored, the fence's KILL not yet due. Either the agent fenced late (it learned
   the lease was gone after the server dropped it, and its KILL waits `fence_stop_ms`), or the
   check's bound (`lost_grace_ms` + 2 checks) assumes TERM works. A real workload may ignore TERM.
   *Acceptance:* the cluster simulation draws `slow_stop` in its runtime faults; the cause on
   seed 90 is found, and the agent or the bound (an owner's call: `lost_grace_ms` is user-visible)
   is changed so that sim-c1 holds with it.

## Also changed

- **check's sim-c1 run is strong (review B, SHOULD 5).** `zig build sim-c1`, which `zig build
  check` runs (seed 1, 100 operations, Debug), now passes `--strong`, and the WASM side follows:
  `zcube_sim_cluster_shaped` takes a last argument, `strong`, which `tools/wasm_check.mjs --sim-c1`
  sets. The native run took 8.3 s plain and 8.0 s strong on this container (one run each), so the
  10 % bound on check's time is not touched; the two WASM runs took 16.2 s and 9.1 s with it.
  Native and WASM reports agree byte for byte.
- **Replay lines of a failing tooth (NIT).** `print_replay` names the tooth's own runner
  (`c1_teeth.runner`, an explicit table: Zig 0.17 cannot list a root's decls) and `--strong` when
  the tooth implies it, e.g. `zig-out/bin/sim_c1_teeth_job_cert_image 240 798 2 --c1 --strong ...`.
- **docs/api.md, ZC-E0130 (supervisor, leftover of PR #233).** The list of what admission refuses
  for a relayed job now also names the image rule (`b3:` and 64 lowercase hex digits) and the
  label-character rule, as `validate_shape` and `job_cert.zig` enforce them. The general label
  limits (32-byte keys, 128-byte values) are tighter than the certificate's, so no other rule is
  missing.

## Measurements

Seeds 1..240, drawn operations, `--profile=auto`, `--c1` (`--strong` implied by every tooth
below), ReleaseSafe, 2026-11-14, on the world with `stop_takes_grace`:

| Runner | Caught | With its symptom | Floor | Seeds | P(miss) |
|---|---|---|---|---|---|
| `sim_c1_teeth_job_cert_stale` | 104 of 240 | 104 | 0.3 | 60 | 5.1e-10 |
| `sim_c1_teeth_job_cert_image` | 92 of 240 | 92 | 0.25 | 80 | 1.0e-10 |
| `sim_c1_teeth_job_cert_long` | 235 of 240 | 235 | 0.8 | 20 | 1.0e-14 |
| `sim_c1_teeth_relay_conn_leak` | 223 of 240 | 222 (seed 189 fails R7 first) | 0.7 | 20 | 3.5e-11 |
| `sim_c1_teeth_relay_stop_leak` | 95 of 240 | 95 | 0.25 | 80 | 1.0e-10 |

The positive run, `sim_cluster --seeds 1..240 auto --profile=auto --c1 --strong` with every tooth
off: POSITIVE_RESULT.
