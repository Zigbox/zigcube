# Handoff: start Zigcube (C0, then C1)

You are starting Zigcube, the orchestrator for Zigbox. Zigbox (a rootless, content-addressed container runtime in Zig, repo `Zigbox/zigbox`) is being built in parallel and does not exist yet. Your job is the control plane and node agent, developed against a **fake runtime**, so that real Zigbox drops in later behind a fixed interface.

Read this whole file and `DIAGNOSTICS.md` before writing code. When something here is ambiguous, ask the human rather than guessing; the decisions marked **Ask first** below are not yours to make alone.

## What Zigcube is

Zigcube runs Zigbox workloads across a fleet. It keeps Kubernetes' one good idea (desired state, reconciled by controllers against a watchable store) and drops the plumbing around it.

Principles:

1. One thin node agent (`zcube-agent`) that links the runtime as a library. No CRI, no containerd, no shims. **Recorded exception (owner, 2026-10-26):** each container runs under a `zbx` supervisor process, because only a container's parent can collect its exit status across an agent restart and `start` needs a single-threaded caller. The supervisor is `zbx` itself, not a separate shim binary or daemon. See `docs/contracts-review.md`.
2. Designed diagnostics from the first commit (see `DIAGNOSTICS.md`): every failure is a short, coded explanation with a cause and a fix, more detail on request, and a full bundle only when needed. Never a raw stack trace or bare Zig error name.
3. Explainable reconciliation: every controller decision is recorded with its cause, so `zcube why <thing>` answers "why is this not running" in one command.
4. Pluggable control-plane storage behind a narrow versioned key-value interface (below). Postgres first, SQLite second.
5. Later milestones add store-aware scheduling, peer chunk distribution, node-side signature checks and grant-based networking. Do not build those now, but do not design them out.

## Scope of this handoff

Deliver **C0** completely, then **C1**, both against the fake runtime. Stop before C2 and report.

Out of scope: real Zigbox integration, networking between workloads, images, signing, the edge proxy, a Kubernetes API facade.

## Decisions already made

| Topic | Decision |
| --- | --- |
| Language | Zig for everything (CLI, server, agent). Pin the latest stable Zig release in `build.zig.zon` and CI; upgrade only between milestones. |
| Binaries | `zcube` (CLI), `zcube-server` (API plus controllers), `zcube-agent` (one per node). One build, three executables. |
| Service files | ZON (Zig Object Notation), e.g. `hello.zon`. |
| Storage | Pluggable `Store` interface. Backend 1: Postgres 16+ (OrioleDB tables when the extension is present, plain heap otherwise; the schema must work on heap). Backend 2: SQLite, for dev, tests and single-node use. |
| Agent ↔ server | HTTP/1.1 + JSON. Agents watch desired state and report observed state; the server never pushes to agents. |
| Diagnostics | `DIAGNOSTICS.md` is binding: the `Diag` collector, the code registry (`ZC-` codes), output modes, bundles and golden tests are part of C0, not later polish. |
| Licence | Apache 2.0. Every commit signed off (`git commit -s`, DCO). No CLA. |

## The two contracts

These two interfaces are the most important things you will write. Both report failure through the shared `Diag` type from `DIAGNOSTICS.md`, so a runtime failure on a node reaches `zcube why` intact. Get them reviewed by the human before building much on top of either.

### 1. `Store`: control-plane storage

A versioned key-value store with etcd-like semantics. Controllers and the API server use only this; no backend-specific SQL above this line.

Operations:

- `get(key, at_revision?)` → value + `mod_revision`
- `list(prefix, at_revision?, limit, continue)` → values + the store revision they were read at
- `txn(compares[], on_success_ops[], on_failure_ops[])` → compare-and-swap on keys' `mod_revision`; ops are put and delete. Small transactions only.
- `watch(prefix, from_revision)` → ordered stream of put/delete events. **No gaps, no reordering.** If `from_revision` has been compacted, return an explicit "compacted" error so the caller relists.
- `lease_grant(ttl)`, `lease_keepalive(id)`, `lease_revoke(id)`; keys can be attached to a lease and are deleted when it expires.
- `compact(revision)`.

Requirements:

- One global, monotonic revision per store. Every write gets the next revision.
- **Postgres gap hazard:** sequence values can commit out of order, so a naive `WHERE revision > N` watch can skip events. Solve it (for example, serialize revision assignment, or hold back watchers until no lower revision is still in flight). k3s's kine project hit the same problem; study it before designing yours.
- A **backend conformance suite** (`zig build test-store -Dbackend=postgres|sqlite`) that every backend must pass: CAS races, watch ordering under concurrent writers, watch resume after reconnect, compaction errors, lease expiry deleting keys. CI runs it for both backends.

Key layout (suggested; keep it documented in `docs/keys.md`):

```
/services/<name>                desired service spec
/replicas/<service>/<id>        desired replica (assigned node, image digest)
/nodes/<node>                   node registration, attached to the node's lease
/observed/<node>/<replica>      what the agent reports (status, exit reason)
/decisions/<id>                 one controller decision: actor, action, reason, cause → another decision id or observed key
/decisions-by-subject/<kind>/<name>/<id>   index for zcube why
```

On Postgres, the observed and decision tables are the hot, update-heavy ones; create them `USING orioledb` when available.

### 2. `Runtime`: what the agent drives

This is the contract with Zigbox. Zigbox will implement it as a library; you implement `FakeRuntime` now.

```zig
pub const ExitReason = union(enum) {
    exited: u8,          // exit code
    signaled: u8,        // signal number
    oom,                 // memory limit hit
    pid_limit,
    start_failed: Diagnostic, // a full diagnostic, e.g. ZBX-E0501 image not found
    lost,                // process vanished without a known reason
};

pub const Spec = struct {
    image: []const u8,   // tree digest, e.g. "b3:51aa…9c03"
    command: []const []const u8,
    env: []const [2][]const u8,
    limits: struct { cpu_millis: ?u32 = null, memory_bytes: ?u64 = null, pids: ?u32 = null },
    labels: []const [2][]const u8, // must include zcube.replica=<id> for re-adoption
};

pub const Status = union(enum) { starting, running, stopped: ExitReason };

// Runtime operations (vtable): start(Spec) -> Handle, stop(Handle, grace_ms),
// inspect(Handle) -> Status, list() -> []Handle (with labels), and an event
// stream of status changes. list() after an agent restart must return
// containers started by the previous agent process.
```

`FakeRuntime`:

- Runs the command as a plain host process (no isolation).
- Persists handle and labels in a state directory so a restarted agent re-adopts running processes instead of starting duplicates.
- Treats a digest as valid only if it appears in a fixtures file (`fixtures/images.zon`); anything else returns `start_failed` with a registered diagnostic (use a placeholder `ZBX-` code agreed with the Zigbox side, and note it in `docs/runtime-codes.md`).
- Supports fault injection for tests: force `oom`, `pid_limit` or `lost` on a named replica.

**Ask first** before changing the `Runtime` interface's semantics once the human has approved it: the Zigbox side will be building to it.

## C0 · Loop: one node keeps a promise

**Goal:** declare a service, and a controller keeps reality matching it on a single node.

Build: `zcube-server` with the `Store` (Postgres and SQLite), the service and replica controllers, the API; `zcube-agent` with `FakeRuntime`; CLI commands `zcube apply <file>`, `zcube get service|replicas [name]`, `zcube why <kind> <name>`.

Reconciliation is level-triggered and idempotent: controllers compare desired and observed state on every relevant change and on a periodic resync, and every action they take writes a decision record with its cause.

Example service file:

```zig
.{
    .name = "hello",
    .image = "b3:51aa9c03",
    .replicas = 3,
    .command = .{ "sh", "-c", "while true; do sleep 1; done" },
}
```

**Demo script** (becomes `zig build demo-c0`, which asserts the same outcomes):

1. `zcube apply hello.zon` with `replicas = 3`. `zcube get service hello` shows 3 running within seconds.
2. `kill -9` one of the processes on the host. A replacement starts; `zcube get` shows 3 again.
3. Change to `replicas = 5` and apply: two more start. Back to 2: three stop.
4. Apply a service whose digest is not in the fixtures. `zcube why service broken` prints the causal chain, each step rendered as a diagnostic:

   ```
   service broken: 0/1 running
     ← replica broken-1 pending on node1
     ← error[ZBX-E0501]: image not found
         cause  digest b3:00ff…e1 is not in this node's store
         fix    check the digest in broken.zon, or pull the image first
   ```
5. Stop Postgres mid-demo and run `zcube get service hello`. The CLI prints a `ZC-` diagnostic blaming the store backend, with a fix, not a connection-library error. Run `zcube bundle --last` and show the manifest.

**Acceptance criteria:**

- Restarting `zcube-server` mid-demo changes nothing; restarting the agent re-adopts running processes instead of duplicating them.
- Every controller action is recorded with its cause and visible to `zcube why`.
- The whole demo passes on both the Postgres and SQLite backends.
- The diagnostics machinery from `DIAGNOSTICS.md` exists and is used everywhere: code registry with build-time checks, `zcube explain`, default/verbose/JSON output, bundles with redaction, golden tests, and the CI check that no user-facing output contains a stack trace.

## C1 · Fleet: placement and failover

**Goal:** workloads spread across nodes and survive the loss of one.

Build: node registration attached to a store lease; a scheduler with resource fit (CPU, memory from the node's declared capacity) and spread; lost-node detection on lease expiry; rescheduling; `zcube get nodes`.

With the fake runtime, "nodes" can be several agent processes on one machine with separate state directories, or a few VMs. A script in `demo/` must bring the demo environment up from nothing.

**Demo script** (`zig build demo-c1`):

1. Three agents join. `zcube get nodes` shows them with capacity.
2. Apply `hello` with `replicas = 6`. `zcube get replicas -o wide` shows two per node.
3. Kill one agent (simulating power-off). Within the lease timeout, its two replicas are marked lost and restarted on the survivors.
4. Restart that agent. It rejoins empty; `zcube why node node3` explains why nothing moved back (no rebalancing by default).

**Acceptance criteria:**

- Lease timeout is configurable and printed at failover.
- An agent that loses its lease stops its own workloads, so a replica never runs twice for long. Test this with a simulated partition (agent alive but unable to reach the server).

## Working rules

- Demo-first: a milestone is done when its demo script passes start to finish on a clean machine, not when unit tests pass.
- Never break an earlier demo. CI runs every `demo-*` and the store conformance suite on every change.
- Error messages are part of the product: follow `DIAGNOSTICS.md` for every failure path, and run its review checklist before each commit that touches one.
- Small, reviewable commits with DCO sign-off.
- Add a dependency only with a written reason in the commit message. Postgres and SQLite client libraries are expected; check maturity before choosing one.
- When a milestone's demo passes, update `site/index.html`: set that milestone's `status` to `"done"` and replace its `demo` lines with real recorded output. Set `"wip"` when you start one.

**Ask first** about:

- Any change to the `Store` or `Runtime` interfaces once approved.
- Any schema or key-layout choice that only works on one backend.
- Adding a third storage backend, or anything outside C0 and C1.

## Open questions to raise, not decide

Answered provisionally on 2026-10-26 ("good enough for now"): build to these, and raise a change
only if the work shows one is wrong. The reasoning is in `docs/contracts-review.md`, section 5.

- Node capacity: **provisional: declared in agent config.** An `auto` mode that reads
  cgroup-aware host limits can come later.
- Watch transport: **provisional: long-poll HTTP.** Propose alternatives only with evidence.
- Retention for decision records: **provisional: newest 200 per subject and at most 7 days,
  whichever is fewer; 24 hours after the subject is deleted.** Details in `docs/keys.md`.
