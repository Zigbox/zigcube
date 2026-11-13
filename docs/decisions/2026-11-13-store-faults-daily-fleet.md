# test-store-faults runs once a day on the fleet host

Status: decided in C3 slice 2.

- A "seed" of kind `store-faults` is one runner invocation (sqlite, postgres, failover sync,
  failover async), because each prints its own seed. Operations are not counted.
- Fingerprints hash the kind, check and step, never the seed.
- Missing Postgres or a failing `pg-up` is "could not start" (step `setup`): counted, never
  filed. A crash, a timeout, or output with no header (build failure) is filed as a crash.
- The day is recorded after the run even when the report failed; the failed round is kept like
  the other kinds', so the next day finds a real failure again.
- `SIM_FLEET_STORE_FAULTS` defaults to 1: a new default for the host, not a product bound.
  No diagnostic code is registered.
- The host needs `postgresql-16` (setup.sh installs it and disables the system service); the
  runs use throwaway servers as `simfleet` under `/var/lib/sim-fleet`. No KVM.
