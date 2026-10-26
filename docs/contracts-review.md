# Review pack: the `Store` and `Runtime` contracts

For the owner. HANDOFF says both interfaces are reviewed before much is built on them, and that
changing either afterwards is an **Ask first**. The code is `src/store.zig` (with the reference
implementation `src/store_memory.zig`) and `src/runtime.zig`. Every choice below is one I made
because HANDOFF left it open or because Zigbox's real module forced it. Approve, or tell me
what to change.

Compared against `Zigbox/zigbox` `main` at `19984dc` (M0 and M1 shipped), reading
`src/zigbox.zig`, `src/runtime/run.zig`, `src/runtime/spec.zig`, `src/diag/*`, `src/host*.zig`.

## 1. `Runtime`: where HANDOFF's sketch and the real `zigbox` module disagree

| # | HANDOFF sketch | `zigbox` as built | What I did |
| --- | --- | --- | --- |
| 1 | `Spec{image, command, env, limits, labels}` | `Spec{rootfs, name, command, labels}`. `rootfs` is a directory (the image digest takes its place in M4). **No `env`, no `limits`** (environment is fixed: PATH, HOME, HOSTNAME, TERM; limits are M2). | Kept HANDOFF's fields. The adapter will map `image` to a root directory for now, and must refuse a non-empty `env` or `limits` until Zigbox grows them. **Zigbox gap.** |
| 2 | `labels: [][2][]const u8` | `labels: []const Label{key, value}`, bounded keys and values | Adopted `Label{key, value}` (and `EnvVar{name, value}`). Clearer, same data. |
| 3 | name not specified; re-adoption by label `zcube.replica` | `name: ?[]const u8`, generated `zbx-xxxxxx` if null; hostname-label rule, 63 bytes | `name` is **required** and is the replica id; label still required. Same name rule as Zigbox. |
| 4 | `start(Spec) -> Handle` | `start(host, spec, options, *Handle, *Diag) Error!void`. Needs a `Host`; `Handle` is a multi-kilobyte struct that **must not move** and **holds pointers into the `Spec`'s strings** until `wait` returns | `Handle` in the contract is the container's **name** (copyable, serialisable, survives an agent restart). The adapter owns a fixed pool of pinned Zigbox handles and copies each spec into its slot. |
| 5 | `Status = union{starting, running, stopped: ExitReason}` | `Status = enum{starting, running, stopped}`; the reason comes only from `wait` | Kept HANDOFF's union. The adapter composes it. |
| 6 | no `wait`; an **event stream** | `wait(*Handle) ExitReason`: **blocking, once per run, and it forwards the signals the calling process receives** to the container | Contract has `events` (status changes, a hint) plus `list` and `inspect` (the truth). `wait` is not in the contract. See 12. |
| 7 | `stop(Handle, grace_ms)` | only `signal(*Handle, number)`; M2 adds `stop` as SIGTERM, timer, SIGKILL | Contract has `stop`. `signal` is **not** in the contract (the agent never needs one). |
| 8 | `list() -> []Handle` with labels; must return containers of a previous agent process | none yet. M2: read the run-records directory; re-adoption by pid in a later record version | Contract has `list` returning `{handle, labels, status}`, including stopped containers (bounded retention, no `forget`). **Zigbox M2 dependency**, as `docs/SPEC.md` already says for C0. |
| 9 | `ExitReason{exited, signaled, oom, pid_limit, start_failed: Diagnostic, lost}` | `{exited, signaled, start_failed: Diag, lost}`; `oom`, `pid_limit` arrive with M2 | Kept HANDOFF's. `start_failed` is Zigcube's plain-data `Diagnostic` (`src/diagnostic.zig`), because Zigbox's `Diag` is typed to the `ZBX-` registry. |
| 10 | `lost` bare | `lost` bare, but the `Handle` keeps `lost_diag` explaining why | Kept bare. **Recommendation: `lost: ?Diagnostic`**, otherwise the explanation Zigbox computed is thrown away. Your call; it is a one-line change now and an Ask-first later. |
| 11 | failure through `Diag` | `Diag` with a `ZBX-` code; `Error` is a Zig error set | A failed *start* is an outcome (`StartOutcome.failed`), so a `ZBX-` diagnostic is never forced into a `ZC-` `Diag`. Failures of the runtime itself use `ZC-E0501` and `ZC-E0502` with `*Diag`. |
| 12 | (not mentioned) | **`start` asserts, in debug builds, that the process has exactly one thread** ("namespace setup must happen before any thread exists", Zigbox M1 acceptance). `host_real` keeps `errno_last` in a process-wide global. | **A real conflict with the agent**, which serves HTTP and reconciles. See below. |

### The threading conflict (item 12), and what I recommend

An agent that is single-threaded for ever would be a poor design, yet Zigbox's `start` refuses
to run in a threaded process, and `wait` blocks and forwards the agent's signals (a SIGTERM to
the agent would be forwarded to every container). The sentence at the top of
`runtime/run.zig`, "a detached run is `start` without `wait` in a supervisor process that is
not the caller", suggests Zigbox's own answer: **one small supervisor process per container**,
which is single-threaded, calls `start` and `wait`, and writes the run record; the agent starts
supervisors, reads records for `list`, and gets exits from the record or a pipe. That also gives
re-adoption for free (the supervisor outlives the agent). I wrote the contract so it fits
either that model or an in-process one, but **this is the question for the Zigbox owner**: will
M2 expose the detached/supervised run, `list`, and an event fd as a library API, and is
"threads in the caller" meant to be unsupported? Until that is answered `FakeRuntime` is
unaffected, and nothing in C0's demo against the fake depends on it.

### `Runtime` choices to approve

1. `Handle` is a name (`name_bytes_max = 63`), not Zigbox's struct.
2. `start` returns `Error!StartOutcome`; a container that did not start is `.failed` with a
   `Diagnostic`, not an `Error`. The agent records it as the replica's observed state.
3. No blocking `wait`. `events(arena, timeout_ms)` returns status changes since the last call;
   it is a hint (an agent restart loses it); `list` and `inspect` are the truth, so
   reconciliation stays level-triggered.
4. `stop(handle, grace_ms)` returns once the container has stopped; idempotent.
5. `list` includes stopped containers until the runtime's own bounded retention drops the
   oldest; the agent must record exit reasons promptly. No `forget`.
6. `Spec.name` required; label `zcube.replica` required; bounds in `constants.zig`.
7. `Error = {NotFound, RuntimeFailed}` with `ZC-E0501` and `ZC-E0502`.
8. Memory: slices in results come from the caller's arena; the runtime copies what it keeps
   from the `Spec`.
9. `signal` is omitted; `lost` stays bare (see item 10, my recommendation to change it).

## 2. `Store`: choices to approve

1. **One revision per committed transaction**, shared by all its events; a transaction that
   changes nothing takes none. (etcd's rule; HANDOFF's "every write gets the next revision"
   admits a per-operation reading too.) A watcher resumes from `revision + 1`.
2. **Compares are `mod_revision ==` only**, with 0 meaning "absent". That one form is
   create-only, update-if-unchanged and delete-if-unchanged. No `<`, `>`, value or version
   compares.
3. **Ops are `put` and `delete` only.** No reads inside a transaction, no prefix delete.
   Duplicate keys in one branch are a programmer error (asserted).
4. **Watch is pull-based**: `Watch.next(arena, timeout_ms)` returns a batch plus a **bookmark
   revision**; a batch never splits a revision; an idle watch still advances its bookmark;
   `Compacted` is an explicit error. It maps one to one onto the long-poll HTTP endpoint. Slots
   are bounded (`store_watches_max`), taken at `watch` and returned at `close`.
5. **Compaction point semantics**: reads at `revision >= compacted_revision` work, below fail;
   a watch needs `from_revision > compacted_revision`.
6. **Pagination**: `continue_after` is the last key returned; pass the first page's `revision`
   as `at_revision` for a consistent read. `limit <= 500`, a page also ends at 4 MiB of values.
7. **Additions beyond HANDOFF's operation list** (each is a method you did not list):
   `status()` (current and compacted revision), and `expire_leases()` (an explicit tick, so no
   backend starts a thread and expiry is deterministic in tests). `lease_keepalive` returns the
   `Lease`; a lease past its deadline **cannot be renewed** even before it is reaped; one lease
   holds at most 64 keys, so a revoke fits in one watch batch.
8. **Errors**: `{Compacted, FutureRevision, LeaseNotFound, TooLarge, NoCapacity, BackendFailed}`,
   each failure with a `ZC-E02xx` diagnostic filled in; the table is in `store.zig`.
9. **Memory**: results come from the caller's arena (`request_arena_bytes_max`, 16 MiB); the
   store copies what it keeps and holds no reference to arguments after returning.
10. **Limits**: key 512 B, value 256 KiB, 16 compares, 16 ops per branch.
11. **Clock seam**: `src/clock.zig`. Postgres uses its own `clock_timestamp()` for leases, so
    that two servers agree; SQLite and the memory store use the injected clock.
12. **Postgres revision assignment serialises writers** on one meta row
    (`docs/store-design.md`). It makes the watch gap-free by construction and costs write
    throughput (hundreds to low thousands of revisions/s). Benchmark at C1 as SPEC says.
13. **OrioleDB** is applied to `store_live` only, not to separate observed/decision tables
    (HANDOFF's wording), because in a key-value store those are key ranges. Physically
    separate tables would be a key-routing layer; say if you want it.

## 3. Diagnostics recommendation

See `docs/diagnostics-plan.md`. Short version: Zigbox's `Diag` is typed to the `ZBX-` registry
and its renderer hard-codes `ZBX-`, so a second registry **cannot** be plugged in without a
change to Zigbox, and "adopting the real one only changes an import" does not hold. I recommend
**option D**: ask the Zigbox owner to expose the plain `Diagnostic` data type (with JSON) and a
`Product`-parameterised `render`; each product keeps its own small collector and registry.
Until you decide, Zigcube keeps the shim (`src/diag.zig`) and the plain-data
`src/diagnostic.zig`. The `zigbox` dependency is not added; `docs/STYLE.md` already names it as
allowed, so I expect you to say yes, but HANDOFF reserves the decision.

## 4. `docs/STYLE.md`, "Where Zigcube departs": wrong or missing

- **Threads are not addressed.** Zigbox's rules assume one thread and its `start` enforces it.
  Zigcube's server and agent need concurrency. The departures need a rule: threads or an evented
  `std.Io` loop, and which code may run where (item 12 above makes this concrete for the agent).
- **`zig build tidy` is cited but absent.** Zigbox's rules lean on it (line and function length,
  banned patterns, `catch unreachable` comments, assertion density). Zigcube has no `tidy`
  step and `AGENTS.md` does not list one. I checked the 100-column and 70-line limits by script
  this slice. Proposal: port `src/tidy.zig` next slice.
- **"No allocation after startup" needs its exception stated for stores.** The departure
  covers per-request arenas; it does not say that a store *backend* (libpq results, SQLite
  statements) allocates inside the backend library. I assumed that is outside the rule and
  bounded by the arena limits at the `Store` boundary.
- **Zig 0.17 traps worth a line**: no `**` array repetition (added `test_util.repeat`), a function parameter may not shadow a method
  name, and `@cImport` is gone (already noted). Std's `ArrayList` is unmanaged by default.
- **Bounded `Diag` text and the `ZBX-` code width.** `diag_code_bytes_max` is 9 so that a
  `ZBX-E0501` fits a `Diagnostic`; any future registry prefix longer than four bytes needs it
  raised.
- **Build tooling "in Zig, not shell"**: `.claude/hooks/session-start.sh` and the `setup-zig`
  action's `run:` blocks are shell. Both predate this slice, and Zigbox's action is the same.

## 5. HANDOFF's three open questions: recommendations

1. **Node capacity: declared in agent config.** C1's demo runs three agents on one machine;
   measuring would make each claim the whole host, and the scheduler's tests need
   deterministic numbers. Add an `auto` mode later that reads cgroup-aware limits.
2. **Watch transport: HTTP/1.1 long-poll, as the default says.** `Watch.next` is already
   long-poll shaped. `GET /v1/watch?prefix=&from=` waits up to ~30 s, answers with a batch and
   the bookmark, and answers **410 Gone** carrying the `ZC-E0203` diagnostic when the position
   is compacted. I have no evidence against it; streaming or WebSocket would add keepalive and
   framing to write for no measured gain. Revisit only if the C1 fan-out benchmark says so.
3. **Decision retention: newest 200 per subject and at most 7 days, whichever is fewer;
   24 hours after a subject is deleted.** Details in `docs/keys.md`. Decisions embed a copy of
   their cause's diagnostic so they survive compaction of the observed record.

## 6. Other things that seemed wrong or worth knowing

- **Zigbox's `DIAGNOSTICS.md` on `main` is identical to ours.** The exit-code table for
  commands that run a container (125 to 128) exists only on Zigbox's branch
  `claude/blissful-cannon-7pcv0x`, which I read for reference. Nothing in Zigcube uses it yet.
- **HANDOFF says the key layout puts the agent's replicas under `/replicas/<service>/...`**:
  one node cannot be selected by prefix. Proposed `/assigned/<node>/<replica>` index is in
  `docs/keys.md`.
- **`ExitReason` and `Status` carry a `Diagnostic` by value** (5 KB measured; Zigbox's `Diag`
  collector, with its bundle path, is 9 KB), as in Zigbox's `start_failed: Diag`. Event batches
  are limited to 64 for that reason.
- **CI's `actions/checkout` SHA** is copied from Zigbox's workflow (`3d3c42e...`, v7.0.1); I
  could not verify it against GitHub from here. `setup-zig` is Zigbox's, unchanged.
