# A relay that cannot be served ends the job as killed by signal 9

*Decided 2026-11-11, by the supervisor (B3 slice 4, review of #216).*

**Decision.** On `--runtime zigbox`, when the supervisor cannot serve a job's relay (no listener
from the container, a bad address, no memory, no thread), it kills the container and writes
ZC-E0702 with its cause to `relay.log`. The job ends as Zigbox's run record says: killed by
signal 9. It is not reported as a start failure. `docs/api.md` says so.

**Why.** Reporting it as a start failure means preferring `failed.json` over Zigbox's run record
when both exist, which changes the status mapping for every job, not just relayed ones. B3 cuts
scope and keeps the demo.

**Follow-up.** A relay failure reported as a start failure (ZC-E0702 in `zcube job get` and `why`)
is a separate change after the B3 release.

**Also accepted as a cut.** The relay stops after `zigbox.wait` has written the run record, not
before it (docs/demos/b3.md): Zigbox gives no hook between the reap and the record.
