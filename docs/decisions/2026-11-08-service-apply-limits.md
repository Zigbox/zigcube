# Service apply checks container limits against the runtime's bounds

Status: **adopted** (B2, 2026-11-08, issue #181). Follows the job check of slice 3 (#178).

**Decision.** `apply.plan` refuses a service whose `limits.cpu_millis` is outside 10 to 1,024,000
or whose `limits.memory_bytes` is outside 4 MiB to 2^40, with ZC-E0104 and a cause naming the
member (`limits.cpu_millis must be 10 to 1024000, it is 0`). The bounds are the `job_limit_*`
constants. No new code: ZC-E0104 is what apply already answers for invalid input, and its
explanation now mentions the bounds. A service has no `pids` limit.

**Behaviour change.** An apply with an out-of-bounds limit used to be accepted (and the replica
then failed in the runtime); it is now refused with `400`, and nothing is written.

**Already-stored services.** The check is skipped when the input's limits equal the stored
service's limits. A cluster that holds an out-of-bounds service keeps working: applying the same
file is `unchanged`, and a change to image, replicas, command or env still goes through. Changing
the limits themselves to another value is checked. Refusing the identical re-apply would make
`zcube apply` of an untouched file start failing after an upgrade, with nothing the operator
changed; the stored limits are the operator's old choice, the new value is a new one.

**Not done.** Job limits and the replica controller are untouched. `job_api.zig`'s validator is
private and takes `JobLimits`; services have their own two-member check in `apply.zig`.
