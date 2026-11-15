# test-store-faults runs once a day on the fleet host

Status: decided in C3 slice 2.

- A "seed" of kind `store-faults` is one runner invocation (sqlite, postgres, failover sync,
  failover async), because each prints its own seed. Operations are not counted.
- Fingerprints hash the kind, check and step, never the seed. The history checker, the watch
  checker (`watch: <kind>`) and a client thread that stopped (`client thread stopped: <error>`)
  are separate checks (review fix).
- Missing Postgres or a failing `pg-up` is "could not start" (step `setup`): counted, never
  filed. A crash, a timeout, or output with no header (build failure) is filed as a crash.
- A non-zero exit is always filed (review fix): a failed conformance test of the Postgres
  step is a failure at step `conformance` even when every runner passed; a step that failed
  after every run passed is a crash at `after-run`; a kill by SIGKILL (exit 137, or a child
  the build saw killed) says it was for memory.
- A replay runs exactly the part that failed, alone (review fix): the new build option
  `-Dstore-faults-only=conformance|faults|sync|async` and the run's seed, with `zig build
  pg-up &&` first when the part needs the fleet's database.
- The day is recorded only once the reporter took its output (review fix; this replaces the
  first version's "recorded even when the report failed"). A report GitHub or a timeout
  stopped is kept in `state/store-faults-pending/` and sent again, without a new run, the
  next round; one the reporter refused (exit 1, bad input) is never retried, since the same
  text gets the same answer, and stays in `state/last-failed-round-store-faults.txt`.
- `SIM_FLEET_STORE_FAULTS` defaults to 1: a new default for the host, not a product bound.
  No diagnostic code is registered.
- The host needs `postgresql-16` (setup.sh installs it and disables the system service); the
  runs use throwaway servers as `simfleet` under `/var/lib/sim-fleet`. No KVM.
