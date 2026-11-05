# The simulation fleet

One host that runs the simulators (`sim_cluster`, `sim_cluster --c1` and `sim_swarm`) on fresh seeds around the clock, at the tip of `main`, and files what it finds. C1 ships only while it runs (`docs/briefs/c1.md`, "Gate for shipping C1"); this is how to put it up. The brief is `docs/briefs/c1-9.md`.

## What runs

`run.sh` (under systemd, as the unprivileged user `simfleet`, one loop per state directory: it takes `flock` on `state/lock`) loops over rounds:

1. `git fetch origin main` (5 minute deadline). If the tip is a commit it has not built, check it out and `zig build -Doptimize=ReleaseSafe --prefix state/bin/<sha> sim-cluster-exe sim-swarm-exe sim-fleet-exe` (1 hour deadline). Only a build that succeeded becomes the one in use (`state/built`); a tip that does not build is recorded in `state/broken`, logged once, and the last good build keeps running. Both survive a restart, so a restart neither rebuilds a good commit nor retries a bad one.
2. **Drawn runs.** `SIM_FLEET_OPS` is `auto` and `SIM_FLEET_PROFILE` is `auto` by default: each seed draws its own size, nodes, lease ttl (8,000 to 10,000 ms until issue #78 is fixed: `docs/decisions/2026-11-05-fleet-ttl-floor.md`), replica counts and fault profile (`docs/core.md`, "Profiles and shapes"), and the summary line reads `drawn operations`. A host installed earlier keeps `SIM_FLEET_OPS=100` in `/etc/sim-fleet/fleet.env`: set it to `auto` there when redeploying.
3. Three kinds of workers, each a parallel run over fresh random ranges (1 hour deadline each): `sim-cluster` (`sim_cluster --seeds A..B auto --profile=auto --shrink`, `SIM_FLEET_BATCH_CLUSTER` seeds, default `SIM_FLEET_BATCH`, 100), `sim-c1` (the same with `--c1`: authority.md's invariants at every revision; `SIM_FLEET_BATCH_C1`, default 100; its summary line reads `sim-cluster --c1: seeds ...`, so output of a run without `--c1` is refused as sim-c1) and `sim-swarm` (`sim_swarm --seeds A..B auto --profile=auto --shrink`: the C2 fetch plan and locality estimate; `SIM_FLEET_BATCH_SWARM`, default 50000). `SIM_FLEET_WORKERS_CLUSTER`, `SIM_FLEET_WORKERS_C1` and `SIM_FLEET_WORKERS_SWARM` set how many workers each kind gets; the defaults are 1, 1 and 1, one core each of the 4 vCPU host, so each kind gets a core. (`SIM_FLEET_WORKERS` of the first release is ignored, with a log line; set a kind to 0 to stop it.) A seed of `sim_swarm` is about 700 times cheaper than one of `sim_cluster` (1.5 ms against 1.1 s, measured 2026-11-04, ReleaseSafe, 100 operations), so a swarm batch is 50000 seeds and ends about when a cluster batch does; the swarm default ignores `SIM_FLEET_BATCH` on purpose, since an installed `fleet.env` already sets that to 100 and `setup.sh` never overwrites it. The tracker's seeds per kind therefore differ by that factor: that is not an imbalance. To rebalance, change the counts or the `SIM_FLEET_BATCH_*` sizes.
4. **The teeth canary.** About 1 round in `SIM_FLEET_CANARY_ONE_IN` (default 50; 0 never, 1 every round) ends by running one fault-on runner picked at random (`sim_teeth`, `sim_swarm_teeth` or one of the six `sim_c1_teeth_*`, built by `sim-canary-exe`, which `run.sh` adds to its build) over seeds 1..10, as `sim-teeth`, `sim-swarm-teeth` and `sim-c1-teeth` do (`--expect-fail`, and for sim-c1 the symptom: `canary_symptom` in `run.sh` copies `c1_teeth_roots`; change both together). It must fail. The round then reports the run kind `sim-canary`: a caught fault is one counted seed on the tracker ("- sim-canary: 1 seeds, 0 failed" is the proof the canary runs); a **miss** is a failure at the step `canary`, filed like any other (an issue titled `sim-canary: the fleet has stopped detecting: <runner> ran seeds 1..10 and none failed`, one issue per runner, a comment on a later commit, the same caps), with the replay `zig build sim-canary-exe && zig-out/bin/<runner> --seeds 1..10 100`. A canary that crashes, times out (`SIM_FLEET_CANARY_TIMEOUT`, 600 s) or is not built is logged and not counted. `sh ops/sim-fleet/test-canary.sh zig-out/bin/sim_fleet` checks it against fake runners and `sim_fleet --dry-run`. No step on the host: it follows `main` and rebuilds.
5. One `sim_fleet ingest --kind K` per kind of the round (10 minute deadline each; the kinds one after another), so the state file has one writer and each failure is looked at once per round.

`sh ops/sim-fleet/test-crash-record.sh zig-out/bin/sim_fleet` checks that a crash record `run.sh` writes for each kind (drawn and fixed operations) is read back by `sim_fleet ingest --dry-run`; run it after changing `crash_record`.

A producer that **crashes** (killed by a signal: a panic is exit 134) loses its range's output, so `run.sh` keeps its output and stderr in `state/crashes/` (the last 20) and replays the range one seed at a time with `--trace-steps` (`sim_swarm` has none: its crash is in the step `run`, with the replay `zig-out/bin/sim_swarm N auto --profile=auto`). `--trace-steps` also writes each seed's concrete replay line (`--profile`, `--lease-ttl-ms`, `--replicas-pct`, `--heal-at`) to stderr as the seed starts, so the crash record carries a full replay and a batch that times out (124) or is killed (137) logs the seed it was on. The batches run with it too. Crash files are named by kind. A seed that crashes again becomes a `seed N: CRASHED: <panic message>` record with the step it was in (the last `step:` line `--trace-steps` wrote, `setup` if none); the other seeds count as usual. A run that timed out (124) or that the kernel killed for memory (137) is the host's: logged, not counted. A seed that could not start (`FAILED: out of memory`, `step: setup`) is counted and never filed.

`sim_fleet ingest`:

- **Fingerprint** of a failure = run kind (`sim-cluster`, `sim-c1` or `sim-swarm`: the same check failing in two kinds is two issues) + the failing check (or, for a crash, the panic message with its digits replaced by `N`, marked as a crash) + the step it failed at (`faults`, `healed`, `convergence`, `end`; for `sim-swarm` `fetch`, `locality`; a crash is the step it was in, `run` for a swarm crash). Not the seed, commit or operation count: one bug is one issue across commits.
- A fingerprint with no issue becomes an issue on `Zigbox/zigcube`, labelled `sim-fleet`: commit, seed, shrunk operations, the one-line replay command (`git checkout <commit> && zig build ... && zig-out/bin/sim_cluster <seed> <ops> ...`; `sim-swarm-exe` and `sim_swarm <seed> <ops>` for a swarm failure, whose title and body say `run: sim-swarm`), and a hidden `<!-- sim-fleet fingerprint: ... -->` marker. Other seeds of the same round that failed alike are listed in it.
- A fingerprint that has an issue (open or closed) gets a **comment** only when it fails on a commit it has not been reported on, and at most 4 times per UTC day. Every seed is still counted in the daily totals. A comment on a closed issue is a regression; reopen it by hand.
- **Parser checks.** The summary line must be the kind's own, and its `F of T failed` must match the `seed N:` records before it and its range; otherwise the whole round is refused (exit 1, logged, nothing counted), so a truncated or mixed-up output never counts a kind as covered.
- **Seeds per day.** The state file counts seeds, failures, crashes, seeds that could not start, and rounds per UTC day, and the seeds of each failure. The state file also counts seeds and failures per kind (`kind` lines, state version 3; a version 1 or 2 file loads, its seeds counted as `sim-cluster`; to roll the fleet back past this release delete `state.txt` and let the markers rebuild it, since the old code reads only versions 1 and 2). The first round after midnight posts the previous day's totals on the **tracking issue** (`SIM_FLEET_TRACKER`) *before* anything else, with the seeds and failures of each kind ("- sim-swarm: 1200 seeds, 0 failed") and the seeds of each failing issue ("- #31: 12 seeds"). No comment for a day means the fleet did not run that day. Look at it daily; that is the alarm.
- **When GitHub says no.** An issue that is gone (404 or 410: deleted or transferred) is forgotten and the failure is filed again. A locked issue (403) is skipped until the next commit. A rate limit (429, or 403 with `Retry-After` or no requests left) stops every write for the round and holds them until the wait GitHub asked for (at most a day) is over; the rounds in between are counted, and their failures are reported when they come back. A tracking issue that refuses the totals is retried each round. A request never follows a redirect, so the token never goes to another host.
- Filed fingerprints are in `/var/lib/sim-fleet/state/state.txt`. If that file is missing, the markers rebuild it (it lists the issues labelled `sim-fleet`, the latest 500). A state file that exists but cannot be read is an error (exit 2); it is never taken for empty.
- Exit codes of `sim_fleet`: 0 done, 1 bad input (a batch cut short is refused, not guessed at), 2 environment (state file, token, GitHub). The state is saved whatever GitHub answered; a round whose filing stopped is kept in `state/last-failed-round-<kind>.txt`, and a failure that is real comes back in a later round.

`sim_fleet --kind sim-cluster|sim-c1|sim-swarm` names the producer of the output; it picks the summary line to expect, the build step in the replay line and the kind in the fingerprint. **Hook for `test-store-faults`** (once a day, not built): add a second parser in `src/sim_fleet_issue.zig` (a failure is `check` + `step` + a replay line), allow its kind in `parse_args` in `src/sim_fleet.zig`, and add a once-a-day branch to `run.sh` that runs `zig build test-store-faults` and pipes its output to `sim_fleet ingest --kind store-faults`. Its fingerprints hash the kind, so they never meet the simulator's.

## What the owner provides

1. **A host**: Ubuntu 24.04, x86_64, 4 vCPU, 8 GB RAM, 40 GB disk or more (the defaults are sized for a Hetzner CPX32: 4 vCPU, 8 GB, 160 GB), outbound HTTPS to github.com, api.github.com and ziglang.org, and nothing inbound. Three cores run the producers (one worker per kind), one is left for the reporter, git and builds. To run more seeds, add hosts.
2. **A token**, a fine-grained personal access token (Settings, Developer settings, Fine-grained tokens):
   - Resource owner: `Zigbox`. Repository access: **only** `Zigbox/zigcube`.
   - Repository permissions: **Issues: Read and write**. Nothing else (Metadata: read is added by GitHub itself).
   - Expiry: the longest the organisation allows; put the date in the calendar. An expired token makes `sim_fleet` exit 2 with `HTTP 401` in the journal and files nothing, and seeds per day stops appearing on the tracker.
   - The label `sim-fleet` must exist in the repository (it does). Without it issues are still filed but are unlabelled, and the recovery of a lost state file cannot find them.
3. **A tracking issue**: "Simulation fleet: seeds per day", pinned. For Zigbox/zigcube it is #29: `SIM_FLEET_TRACKER=29`.

The token only ever sits in `/etc/sim-fleet/token` (root, mode 600). systemd hands the service a private copy (`LoadCredential`), `sim_fleet` reads it from there, and nothing prints it: a refused request logs its method, path and status, never a header. The copy is readable by every process running as `simfleet`, which includes `sim_cluster` and `zig build` of whatever is on `main`: a commit on `main` can read the token. That is why it may only write issues of this one repository.

## Deploy

**Redeploying an existing host** (a release that changed `ops/`, `run.sh`, the state format or the sim_fleet binary): as root,

```
git -C /root/zigcube pull           # the checkout setup.sh is run from, FIRST: setup.sh installs from it
sh /root/zigcube/ops/sim-fleet/setup.sh
systemctl restart sim-fleet
journalctl -u sim-fleet -f
```

Then check the **first tracker post** (the next UTC midnight, or the first round's journal lines): `sim-fleet: sim-c1: N seeds` and `sim-fleet: sim-swarm: N seeds` with N above zero, and the tracker's "Seeds by run" listing non-zero seeds for `sim-c1` and `sim-swarm`. A kind at zero is not covered; do not trust silence. **Rollback:** in the checkout `git checkout <old commit>`, `sh ops/sim-fleet/setup.sh`, delete `/var/lib/sim-fleet/state/state.txt` (the old `sim_fleet` reads only state versions 1 and 2; the issue markers rebuild it, and the per-kind counts of today are lost), `systemctl restart sim-fleet`.

On a fresh host, as root (the exact steps for a fresh host are also in the C1-9 report):

```
cd /root
git clone https://github.com/Zigbox/zigcube
sh zigcube/ops/sim-fleet/setup.sh --token-file /root/github/token
grep SIM_FLEET_TRACKER /etc/sim-fleet/fleet.env      # SIM_FLEET_TRACKER=29
journalctl -u sim-fleet -f
```

`setup.sh` is safe to run again. It installs the pinned Zig (checksum verified; the version is in `build.zig.zon`, CI and `.claude/hooks/session-start.sh` too, and `setup.sh` refuses a checkout that wants another), creates the `simfleet` user, clones the repo to `/var/lib/sim-fleet/zigcube`, stops the service if it runs, builds once (so a broken host shows now), installs the unit and enables it. `--token-file PATH` takes the token from a file, never from an argument value or the environment: it is copied (not printed) to `/etc/sim-fleet/token` with mode 600, and the source file is left alone. Without it, create `/etc/sim-fleet/token` by hand (`install -m 600 /dev/null ...`). The service is (re)started only if the token file is not empty. It also caps the journal at 2 GB. `fleet.env` is copied only if it is not there yet: an existing one keeps its settings.

Defaults (`fleet.env`) are sized for 4 vCPU, 8 GB: `SIM_FLEET_WORKERS_CLUSTER`, `_C1` and `_SWARM` (1 each) parallel producer runs (one core each), round outputs overwritten in place (a few MB of state, plus the binaries of the commit in use), and the build caches (`.zig-cache`, `zig-pkg`, `~/.cache/zig`) emptied before a build once together they pass `SIM_FLEET_CACHE_MB=8192`. The unit caps the service at 7 GB of memory (`MemoryMax`), so the kernel kills a `sim_cluster`, not sshd; `run.sh` logs that and goes on.

The journal shows `building <sha>` when `main` moves and `sim-fleet: <kind>: N seeds, F failed (...): ...` after each kind's ingest of each round. After changing anything in `ops/`, run `setup.sh` again; `run.sh` itself is read from the checkout, so a restart picks up the new one.

## Check that it works (before trusting silence)

- **Dry run**, nothing filed, no token needed. As root, with the service running or not:

  ```
  su -s /bin/sh simfleet -c 'cd && SIM_FLEET_DRY_RUN=1 SIM_FLEET_ROUNDS=1 SIM_FLEET_TRACKER=29 \
      sh /var/lib/sim-fleet/zigcube/ops/sim-fleet/run.sh'
  ```

  A dry run uses its own checkout and state under `/var/lib/sim-fleet/dry/` (it clones and builds there first, a few minutes), never the service's, and prints each would-be issue and comment and the summary line. `SIM_FLEET_ROUNDS=1` stops it after one round.
- **The teeth check**, one would-be issue and then a would-be comment, in any checkout: `zig build sim-teeth-exe sim-fleet-exe`, then `zig-out/bin/sim_teeth --seeds 1..3 100 --shrink > out.txt`, then `zig-out/bin/sim_fleet ingest --dry-run --commit aaa --state /tmp/st < out.txt` and again with `--commit bbb` (the second prints the comment; the same commit again prints neither: one comment per commit). `sim_teeth` is the simulator with the agent's test-only fault on.
- After the first real day: the tracker has a comment for it.

## Limits

- The token files issues and comments; it cannot close, label or delete. Closing and reopening are the owner's.
- The fleet tests the tip of `main` only; it does not look at pull requests.
- One host is a single point of failure by design. The tracker comment is how an outage shows.
- `sim_fleet` has no deadline of its own on a GitHub request (the pinned std HTTP client has none); `run.sh`'s `timeout` is the deadline.
