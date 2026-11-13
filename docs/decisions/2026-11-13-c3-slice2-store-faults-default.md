# SIM_FLEET_STORE_FAULTS defaults to 1

Status: approved by the supervisor, C3 slice 2.

**Value.** `SIM_FLEET_STORE_FAULTS=1` is the default in `ops/sim-fleet/run.sh`, and
`fleet.env.example` repeats it. `SIM_FLEET_PG_BIN` defaults to `/usr/lib/postgresql/16/bin`
and `SIM_FLEET_STORE_FAULTS_TIMEOUT` to 1800 seconds per runner invocation.

**Why.** The brief makes `test-store-faults` a daily fleet job. A host that has run `setup.sh`
has Postgres 16 and should run it without a further setting. It is a host default, not a
product bound: nothing in `zcube-server` changes and no diagnostic code is registered. A host
without the Postgres programs counts the run as "could not start" and files nothing.

**How to change it.** Set `SIM_FLEET_STORE_FAULTS=0` in `/etc/sim-fleet/fleet.env` and
`systemctl restart sim-fleet` to stop the daily run. `run.sh` reads the file at start, and an
unset value (the source-only shell tests) means off.

## Known gap: Postgres tests as `tester` under `zig build check`

With `ZCUBE_TEST_POSTGRES` set, `zig build check` failed in its last step
(`zig build test as tester`): 22 `store_postgres` tests failed, for example
"expected .E0209, found .E0201". E0201 is a connection failure. The same `check` passed
with the variable unset. This slice does not touch the store.

The cause is **not confirmed**. `check` starts that run with `runuser -u tester -- env ...`
(`src/testing/check.zig`), which keeps the environment, so the variable should reach the
tests. I did not look at what `tester` could not reach. Candidates are the throwaway
Postgres under `/tmp/zcube-pg` (owned by `postgres`) and its socket or auth settings, or
the connection string. Whoever next changes the store should run `check` with
`ZCUBE_TEST_POSTGRES` set and look at this first. Until then the PASS line may not name
`postgres`.
