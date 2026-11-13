# B5 slice 4 handoff: demo-b5

Status: built, compiled and rehearsed piece by piece in the cloud container; **not run whole**
(no KVM there). B5 is done only when CI's `demo-b5` job is green (`docs/demos/b5.md`).

## Decisions

- Jobs are posted with `POST /v1/jobs` and `signatures`: `zcube job run` cannot attach a
  signature, and a CLI flag would be new surface the brief did not ask for.
- "An assignment written straight into the store" is a job record written with `job_api.create`
  and `.trust = null` while the server is stopped (`src/demo_b5_inject.zig`); the server's own
  controllers then make the run and assignment. Forging the assignment would test the forgery.
- The signer lives in the guest under its own XDG directories (`/root/signer`), apart from the
  node's store; `zbx trust export` prints every signature of a tree, so the stranger's line is
  found as the one that differs from the release line.
- `guest.sh containers` fails when `<state>/zigbox/` is missing, so "no container" cannot pass on
  a wrong path. Job containers are `<name>-job` (`records.job_run_suffix`).

## Traps

- Zig 0.17 here rejects `"ab" ** 32` in that position; write the literal.
- The test binaries take no `--test-filter`; to see one test run, make it fail on purpose once.
- `zbx key new` has no key-directory flag: steer it with `XDG_CONFIG_HOME`.
- `demo-b5-build` links SQLite and libpq (the inject module opens a store).

## What's next

- Open the PR (supervisor) so CI's `demo-b5` job runs; fix whatever the real VM shows.
- README and site have no B5 rows yet; status is the supervisor's.
