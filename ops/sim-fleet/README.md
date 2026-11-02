# The simulation fleet

One host that runs `sim-cluster` on fresh seeds around the clock, at the tip of `main`, and files what it finds. C1 ships only while it runs (`docs/briefs/c1.md`, "Gate for shipping C1"); this is how to put it up. The brief is `docs/briefs/c1-9.md`.

## What runs

`run.sh` (under systemd, as the unprivileged user `simfleet`) loops:

1. `git fetch origin main`; if the tip is a commit it has not built, check it out and `zig build -Doptimize=ReleaseSafe sim-cluster-exe sim-fleet-exe`. A tip that does not build is logged once and the last good build keeps running.
2. `sim_cluster --seeds A..B 100 --shrink` over a fresh random range (default 100 seeds).
3. `sim_fleet ingest` reads that output (`src/sim_fleet.zig`).

`sim_fleet ingest`:

- **Fingerprint** of a failure = run kind (`sim-cluster`) + the failing check + the step it failed at (`faults`, `healed`, `convergence`, `end`). Not the seed, commit or operation count: one bug is one issue across commits.
- A fingerprint with no issue becomes an issue on `Zigbox/zigcube`, labelled `sim-fleet`: commit, seed, shrunk operations, the one-line replay command (`git checkout <commit> && zig build ... && zig-out/bin/sim_cluster <seed> <ops> ...`), and a hidden `<!-- sim-fleet fingerprint: ... -->` marker. Other seeds of the same batch that failed alike are listed in it.
- A fingerprint that has an issue (open or closed) gets a **comment**, one per fingerprint per batch. A comment on a closed issue is a regression; reopen it by hand.
- Filed fingerprints are in `/var/lib/sim-fleet/state/state.txt`. If that file is lost, the markers rebuild it (it lists the issues labelled `sim-fleet`, the latest 500). Seeds-per-day counts start over.
- **Seeds per day.** The state file counts seeds, failures and batches per UTC day. The first batch after midnight comments the previous day's totals on the **tracking issue** (`SIM_FLEET_TRACKER`). No comment for a day means the fleet did not run that day. Look at it daily; that is the alarm.
- Exit codes of `sim_fleet`: 0 done, 1 bad input (a batch cut short is refused, not guessed at), 2 environment (state file, token, GitHub). A batch whose filing fails is logged and not retried; a failure that is real comes back in the next batch.

`sim_fleet --kind` names the producer of the output, and only `sim-cluster` is built. **Hook for `test-store-faults`** (once a day, not built): add a second parser in `src/sim_fleet_issue.zig` (a failure is `check` + `step` + a replay line), allow its kind in `parse_args` in `src/sim_fleet.zig`, and add a once-a-day branch to `run.sh` that runs `zig build test-store-faults` and pipes its output to `sim_fleet ingest --kind store-faults`. Its fingerprints hash the kind, so they never meet the simulator's.

## What the owner provides

1. **A host**: Ubuntu 24.04, x86_64, 2 or more cores, 2 GB RAM, 10 GB disk, outbound HTTPS to github.com, api.github.com and ziglang.org, and nothing inbound. One core per host is used; add hosts, not threads, to run more seeds.
2. **A token**, a fine-grained personal access token (Settings, Developer settings, Fine-grained tokens):
   - Resource owner: `Zigbox`. Repository access: **only** `Zigbox/zigcube`.
   - Repository permissions: **Issues: Read and write**. Nothing else (Metadata: read is added by GitHub itself).
   - Expiry: the longest the organisation allows; put the date in the calendar. An expired token makes `sim_fleet` exit 2 with `HTTP 401` in the journal and files nothing, and seeds per day stops appearing on the tracker.
   - Create the label `sim-fleet` in the repository once, by hand (the token cannot create labels). Without it issues are still filed but are unlabelled, and the recovery of a lost state file cannot find them.
3. **A tracking issue**: "Simulation fleet: seeds per day", pinned. Its number goes in `SIM_FLEET_TRACKER`.

The token only ever sits in `/etc/sim-fleet/token` (root, mode 600). systemd hands the service a private copy (`LoadCredential`), `sim_fleet` reads it from there, and nothing prints it: a refused request logs its method, path and status, never a header.

## Deploy

On the host, as root:

```
curl -sSfLO https://raw.githubusercontent.com/Zigbox/zigcube/main/ops/sim-fleet/setup.sh
sh setup.sh
install -m 600 /dev/null /etc/sim-fleet/token
$EDITOR /etc/sim-fleet/token            # the token, one line
$EDITOR /etc/sim-fleet/fleet.env        # SIM_FLEET_TRACKER=<issue number>
systemctl start sim-fleet
journalctl -u sim-fleet -f
```

`setup.sh` is safe to run again. It installs the pinned Zig (checksum verified; the version is in `build.zig.zon`, CI and `.claude/hooks/session-start.sh` too, and `setup.sh` refuses a checkout that wants another), creates the `simfleet` user, clones the repo to `/var/lib/sim-fleet/zigcube`, builds once, installs the unit and enables it. It starts the service only if the token file is not empty.

The journal shows `building <sha>` when `main` moves and `sim_fleet: N seeds, F failed: ...` after each batch. After changing anything in `ops/`, copy the unit again (`setup.sh`) and `systemctl restart sim-fleet`; `run.sh` itself is read from the checkout, so a restart picks up the new one.

## Check that it works (before trusting silence)

- Dry run, no token, nothing filed: `SIM_FLEET_DRY_RUN=1 sh ops/sim-fleet/run.sh` as `simfleet` prints what each batch would file. A dry run keeps its own state (`state.txt.dry`).
- The teeth check, to see one would-be issue and then a would-be comment: `zig build sim-teeth-exe sim-fleet-exe`, then `zig-out/bin/sim_teeth --seeds 1..3 100 --shrink > out.txt`, then `zig-out/bin/sim_fleet ingest --dry-run --commit $(git rev-parse HEAD) --state /tmp/st < out.txt` twice (the second prints the comment). `sim_teeth` is the simulator with the agent's test-only fault on.
- After the first real day: the tracker has a comment for it.

## Limits

- The token files issues and comments; it cannot close, label or delete. Closing and reopening are the owner's.
- The fleet tests the tip of `main` only; it does not look at pull requests.
- One host is a single point of failure by design. The tracker comment is how an outage shows.
