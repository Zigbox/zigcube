# Authority, fencing and explanation

**Status: approved in outline by the owner, 2026-10-27, before the C1 brief.** The two key-layout
changes below (the placement split, and reachability-based retention with a `complete`/`truncated`
result from `why`) are owner decisions made under HANDOFF's **Ask first** rule. The rest is the
model C1 builds to. Where this document and [keys.md](keys.md) disagree, this document describes
C1 and keys.md describes C0 until C1 updates it.

This document answers four questions:

1. Who may write each key?
2. When may a controller believe an observation?
3. What does a lease expiry prove, and what fencing follows from it?
4. When is a `zcube why` answer complete?

It also replaces the shorthand "the store is the only state" with something precise.

## 1. Three classes of state

| Class | Where it lives | Authoritative for | If it is lost |
| --- | --- | --- | --- |
| **Intent and decisions** | the store | what should run, and why each action was taken | the cluster is lost; restore the database |
| **Process facts** | each node's state directory (`spec.json`, `run.json`, the supervisor's lock) | what happened to the processes on that host, and only that host | that node's surviving processes are `lost` and are killed (fail safe) |
| **Caches** | server memory, agent memory, later Zigbox's chunk store | nothing | rebuilt from the other two; a restart is the test |

**Why process facts cannot live in the store.** Only a process's parent can collect its exit
status. That parent is the supervisor, on the node. The node is therefore the only place where the
fact "hello-3 exited with SIGKILL" can come into existence and survive an agent restart. The store
holds a projection of these facts, `/observed/<node>/`, which only the node writes (§2).

**Direction of authority:**

- **Intent flows from the store to the node.** If the store says `hello-9` should run generation 4
  and the node runs generation 3, the store wins and the replica is replaced.
- **Facts flow from the node to the store.** If the node says `hello-9` died and the store's last
  observation says it runs, the node wins.
- **A node never holds intent.** The agent never starts a container from local files alone. With
  local files it may only *adopt* a container (one the store still wants) or *stop* it (one the
  store does not want). A state directory that is wiped or corrupt can therefore cause only stops,
  never starts.

**The claim, restated.** Stopping and starting the server or an agent changes nothing, because
class 1 and class 2 are durable and class 3 is rebuilt from them. The C0 demo asserts this byte for
byte for class 1 and with process ids for class 2.

## 2. One writer role per key

Every key prefix has exactly one writer role, so two controllers never contend for one key, and a
failed compare always means the world changed, never that a peer controller got there first.
**This is the owner's decision of 2026-10-27:** the scheduler no longer writes `node` into
`/replicas`.

| Prefix | Sole writer | Holds | Lifetime |
| --- | --- | --- | --- |
| `/services/<name>` | API (`apply`, `delete`) | desired service | until deleted |
| `/replicas/<svc>/<id>` | replica controller | desired replica: spec and generation; **no placement** | until the replica is retired |
| `/assigned/<node>/<id>` | scheduler | the placement: replica id, service, the resolved `requests`, and the reason | until unassigned |
| `/nodes/<node>` | that node's agent | registration and declared capacity | **bound to the node's lease** |
| `/node-status/<node>` | node controller (new) | `ready`, `lost` or `fenced`, the tenure it judged (§3), when, and the decision that set it | until the node is removed |
| `/observed/<node>/<id>` | that node's agent, through the agent endpoint | process facts (class 2, projected) | until the agent or the node controller removes it |
| `/decisions/<id>`, `/decisions-by-subject/…` | whoever acts, in the same transaction as the action | one action and its cause | retention (§5) |

- **`/assigned/<node>/` replaces the `node` field.** An agent's long-poll watches its own prefix,
  so fan-out is O(replicas on the node), not O(all replicas). The agent endpoint joins each
  assignment with its `/replicas` record, so the agent sees the same shape as today.
- **The scheduler moves a replica in one transaction.** It deletes `/assigned/<old>/<id>`, puts
  `/assigned/<new>/<id>` and writes the `place_replica` decision, with compares on the replica and
  on both node records it read.
- **The replica controller never reads `/assigned` to decide anything about the desired set.** It
  reads only to report (`get replicas` shows where each replica runs).

### The read-set rule

A controller's transaction compares the `mod_revision` of **every key whose value justified the
action**, not only the key it writes. If any of them moved, the transaction writes nothing, and the
next step plans again from the new state. This is optimistic serialisability. The approved
`Store` interface already provides it: `Compare` is on `mod_revision`, and 0 means "absent".

`store_txn_compares_max` (16) caps the read set. That is a design pressure, not a problem. An
action that needs more than 16 facts to justify should be split into steps, each of which records
what it decided.

## 3. Tenure, leases and fencing

### Tenure

An agent holds **tenure** on its node while its `/nodes/<node>` key exists. The tenure is
identified by that key's `mod_revision` at registration (the *tenure revision*).

- The agent endpoint accepts a write to `/observed/<node>/` only with a compare that
  `/nodes/<node>` still has the writer's tenure revision.
- When the lease expires, the store deletes `/nodes/<node>`, so every later write from that agent
  fails at the store.
- A partitioned agent that heals cannot write a late observation over decisions already taken
  without it.

This is real fencing, because the store is the shared resource and it checks the token.

**Why not bind `/observed` keys to the lease.** In discussion I proposed attaching every observed
key to the node's lease, so that expiry deletes them. The store forbids it at scale:
`store_lease_keys_max` is 64, because a lease's keys are deleted in one revision and a watch batch
never splits a revision. Binding would cap a node at 63 replicas. The tenure compare gives the same
guarantee, with no cap. The node controller removes a lost node's observed records itself, a page
at a time, each removal with its decision.

### Admissible observations

A controller may act on an observation only if all three hold:

1. its `tenure` field equals the node's current tenure revision;
2. its `assignment` field equals the current `mod_revision` of `/assigned/<node>/<id>`;
3. `/node-status/<node>` is `ready`.

Anything else is evidence about the past. It may appear in `zcube why`, but no action is based on
it. Observed records gain the `tenure` and `assignment` fields in C1. The `assignment` revision is
the **placement epoch**: unique per placement, monotonic, and free, because the store already
assigns it.

### What an expiry proves, and the self-fencing window

**A lease expiry proves only that the server stopped hearing from the agent.** The agent may still
be running its containers. So C1 adds self-fencing on the agent, with a window that rests on stated
assumptions.

- The agent records the time `s` when it **sent** each keepalive that succeeded, on
  `CLOCK_BOOTTIME`. That clock is monotonic, keeps counting through suspend, and is shared by every
  process on the host. The agent persists `s` and the lease id in its state directory, so a
  restarted agent inherits the deadline.
- At `s + ttl − fence_margin` with no newer success, the agent **fences**: it stops every
  container, waiting `fence_stop_ms` before it kills. It then registers again, under a new tenure,
  with nothing running.
- The server's expiry is computed at least `ttl` after it **received** the same keepalive, and the
  receipt is no earlier than `s`. The node controller declares the node lost at expiry, then waits
  `lost_grace_ms` before anything is placed elsewhere.

The agent has finished stopping before any replacement is placed, provided that:

- `fence_margin ≥ fence_stop_ms + ttl × skew + kill latency`, where `skew` bounds the difference
  between the two hosts' clock **rates**. Absolute clock values do not matter.
- The agent process is alive and scheduled.
- The kernel delivers `SIGKILL` and the process exits.

Proposed constants (fixed in the C1 brief): `ttl` 10 s, `fence_stop_ms` 2 s, `skew` 1 %,
`fence_margin` 3 s, `lost_grace_ms` 1 s.

**The stated window for stateless replicas.** Two instances of one replica's *work* can run at
once for at most `lost_grace_ms` plus kill latency, **unless the node is wedged**: the agent is
frozen, or a process is in uninterruptible sleep. In that case the bound fails, and nothing on the
server can know.

For stateless replicas this is acceptable. A replacement has a **new replica id** (ids are never
reused, keys.md). The old instance is therefore never mistaken for the new one, and when the node
returns, the agent stops it because the store no longer wants it.

`demo-c1` and `sim-c1` (§4) assert this window. Neither may claim more.

### Stateful replicas (C7): no move on an expiry alone

C7 must not place a stateful replica on another node because a lease expired. The node controller
moves it only with one of these **fencing proofs**, each recorded as the cause of the `move`
decision:

1. **The node confirms.** It comes back with a new tenure and reports the replica stopped.
2. **An external fence.** A configured hook, for example a hypervisor power-off or an IPMI call,
   reports success. The C7 demo's "power off the VM" is exactly this, and should be done through
   the hook.
3. **An operator's assertion.** `zcube node fence <node> --confirm-dead`, recorded with who said
   it.

The resource must also check the epoch. Every stateful placement's epoch (its `/assigned`
revision) is carried by anything that writes durable state:

- snapshot uploads are conditional on the epoch (a conditional put, or an epoch in the object's
  path that the restore checks);
- the C4 mesh identity of a stateful replica is bound to its epoch, so peers refuse the old
  instance.

This is how C7's acceptance criterion "never runs on two nodes at once" becomes true rather than
probable.

### More than one server (after C1)

Controller leadership will be a store lease on `/leader/controllers`. Every controller transaction
compares that key's `mod_revision` as part of its read set. A deposed leader's writes then fail at
the store, as a partitioned agent's do. C1 runs one server and does not build this. It is required
before a second server may run against one store.

## 4. Checking it: `sim-c1`

`sim-c0` already runs the real core on virtual time, natively and as WASM. `sim-c1` extends the
same world with the following faults:

- partitions, per node and in each direction;
- message delay and reordering;
- clock-rate skew within the stated bound, and beyond it in a negative test;
- agents that die, freeze, or whose kill fails;
- server restarts.

It asserts these invariants after every event:

- **I1.** No replica id has two running instances, except inside the stated window, and never when
  the node is not wedged and skew is within bound.
- **I2.** No transaction commits whose tenure or placement epoch was superseded.
- **I3.** No decision cites an inadmissible observation as its cause.
- **I4.** Every key changed by a transaction was written by its prefix's writer role (§2).
- **I5.** Every `why` answer is `complete` or names its truncation (§5).

The negative test, with skew beyond the bound or a wedged node, must find I1 violated. That is how
we know the simulation can see the failure the bound excludes.

A TLA+ model of the tenure and fencing protocol alone is worth writing before C7, and not before C1.

## 5. When an explanation is complete

### The `why` result says so

`zcube why` and `GET /v1/why/…` return a `completeness` alongside the steps:

- **`complete`.** The chain ends at a terminal (`desired`, `observed`, `lease_expired`, `resync`,
  or a fencing proof). Every step was read at the revision its link cites, or from the copy the
  citing decision embeds.
- **`truncated`.** The chain stops early, with `at` (the last step that was found) and `reason`.
  The reasons are:
  - `retention`: a cited decision was removed;
  - `subject_deleted`: the subject's 24 hours have passed;
  - `compacted`: a cited key has changed since, history before the store's compaction point is
    gone, and the citing decision embedded no copy.

The text output ends a truncated chain with one line saying so. Today that is a `gone` step, which
is already in `src/why.zig`; C1 gives it a reason and puts the verdict in the JSON and the console.

### Retention follows reachability (owner's decision, 2026-10-27)

Today's rule keeps the newest 200 decisions per subject, for at most 7 days. Under it, a crash loop
that writes 200 `replace_replica` decisions in minutes evicts the `apply` that explains the service.
That is the chain an operator most needs.

C1 changes the rule:

1. **Roots.** Each live subject's newest decision.
2. **Pinned.** A retention pass walks each root's chain to its terminal (the same walk as `why`,
   bounded by `why`'s depth limit) and pins every decision on it.
3. **Evictable.** A decision beyond the per-subject budget (newest 200, at most 7 days) **and not
   pinned**.
4. **Deleted subjects.** A deleted subject's decisions are no longer roots, but stay 24 hours.

The cost is one chain walk per live subject per pass. Chains are short (the C0 demo's are 2 to 5
steps), and a pass already works a page at a time.

### Repetition collapses into one decision

When a controller takes the same action on the same subject for the same kind of cause repeatedly,
it updates one **summary decision** instead of writing a new one each time. The summary holds
`count`, `first_at_ms`, `last_at_ms`, the first cause and the latest cause. An example is
`replace_replica` on a service whose replicas keep dying with `SIGKILL`.

- The update is in the same transaction as the action, so "every action is recorded" still holds.
  The record is a counter, not a list.
- This is the one exception to "decisions are written once". Only the writer role that created a
  summary updates it.
- The per-replica decisions of a loop (`create_replica` for each new id) belong to replicas that
  are soon deleted, so they leave after their subject's 24 hours.

## 6. What C1 builds from this, and what it does not

**Built in C1:**

- the split of §2 (`/assigned/<node>/`, `/node-status/<node>`, the node controller);
- the read-set rule;
- tenure compares on the agent endpoint;
- the `tenure` and `assignment` fields on observed records;
- agent self-fencing with a persisted `CLOCK_BOOTTIME` deadline;
- `lost_grace_ms`;
- `sim-c1` with I1 to I5;
- `completeness` in `why`;
- reachability-based retention;
- summary decisions.

`demo-c1` shows the fencing window: the partition test of HANDOFF's acceptance criteria.

**Recorded, not built:**

- the C7 fencing proofs and epoch-checked durable writes;
- controller leadership for a second server;
- the TLA+ model.

**Follow-ups to this document once C1 lands:** keys.md takes the new prefixes and fields, api.md
takes `completeness`, and console.md shows it.
