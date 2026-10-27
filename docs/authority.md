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

**Revision 2 (owner review, 2026-10-27):** a predicate over a set needs an authoritative aggregate
(phantoms, §2), so `/allocations/<node>` is added; decisions are immutable and repetition is
counted beside them (§5); I1 is split into ownership and execution; I6 is added.

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
`/replicas`, and it owns the node's allocation record (below), the one shared writable record in
the layout.

| Prefix | Sole writer | Holds | Lifetime |
| --- | --- | --- | --- |
| `/services/<name>` | API (`apply`, `delete`) | desired service | until deleted |
| `/replicas/<svc>/<id>` | replica controller | desired replica: spec and generation; **no placement** | until the replica is retired |
| `/assigned/<node>/<id>` | scheduler | the placement: replica id, service, the resolved `requests`, and the reason | until unassigned |
| `/nodes/<node>` | that node's agent | registration and declared capacity | **bound to the node's lease** |
| `/allocations/<node>` | scheduler | authoritative accounting: the sum of the `requests` of every assignment on the node, their count, and the `/nodes/<node>` revision whose capacity it was checked against | while the node exists |
| `/node-status/<node>` | node controller (new) | `ready`, `lost` or `fenced`, the tenure it judged (§3), when, and the decision that set it | until the node is removed |
| `/observed/<node>/<id>` | that node's agent, through the agent endpoint | process facts (class 2, projected) | until the agent or the node controller removes it |
| `/decisions/<id>`, `/decisions-by-subject/…` | whoever acts, in the same transaction as the action | one action and its cause; **immutable** | retention (§5) |
| `/decision-summaries/<kind>/<name>/<action>/<cause-kind>` | the actor of the decisions it counts, in the same transaction | a projection over immutable decisions: count, first and last time, the newest decision's id | with its subject |

- **`/assigned/<node>/` replaces the `node` field.** An agent's long-poll watches its own prefix,
  so fan-out is O(replicas on the node), not O(all replicas). The agent endpoint joins each
  assignment with its `/replicas` record, so the agent sees the same shape as today.
- **The scheduler moves a replica in one transaction.** It deletes `/assigned/<old>/<id>`, puts
  `/assigned/<new>/<id>`, updates both nodes' `/allocations` records and writes the
  `place_replica` decision, with compares on the replica, on both node records and on both
  allocation records.
- **Only the scheduler removes an assignment**, and it releases the allocation in the same
  transaction. A replica retired by the replica controller, or a node marked lost by the node
  controller, is a fact the scheduler reacts to; neither of them touches `/assigned` or
  `/allocations`.
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

### Predicates over sets: phantoms

**Comparing the keys that were read is not serialisability when the decision rests on a set.** A
scheduler that sums a node's 12 assignments and compares all 12 revisions still commits on a stale
sum if a 13th assignment was inserted meanwhile: none of the 12 keys moved. The store's `Compare`
cannot see an insert into a range.

So **a decision that rests on a predicate over a set must compare a single authoritative record
that every change to that set also changes.** For capacity, that record is `/allocations/<node>`:

- every transaction that adds or removes an assignment on a node updates that node's allocation
  record, so a concurrent insert moves its `mod_revision` and the stale transaction fails;
- the scheduler places only with a compare on the allocation record and on `/nodes/<node>`
  (whose value holds the declared capacity), and only if the new total stays within it;
- the record is **accounting, not a cache**: it is the authority for what is allocated, and
  `sum(requests of /assigned/<node>/*) = /allocations/<node>.allocated` is an invariant (I6),
  not a hope.

The two alternatives were a range-generation token per prefix, maintained by the store, and a
`txn` that validates range reads. Both change the approved `Store` interface (HANDOFF's **Ask
first**) and push the problem into three backends. The allocation record keeps the invariant local
to one key and needs nothing new from the store.

The same rule applies to any later predicate over a set (C3's surge and unavailable limits, C8's
gang admission): name the aggregate record, its sole writer, and the transactions that must update
it.

**Two edges, stated:**

- **Capacity can shrink under allocations.** An agent may register again with less declared
  capacity than is already allocated. That is not a placement, so it does not break I6. The node
  is over-allocated: the scheduler places nothing more there and records a decision saying so. C1
  does not evict.
- **Accounting is released when the assignment is removed**, which is before the old process has
  necessarily stopped. Physical use can therefore exceed the accounting for up to the stop grace
  (`stop_grace_ms`). Allocation is a promise about placement, not a measurement.

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

It asserts these invariants after every event. I1 is split, because owning a replica and running
it are different claims: the first can be guaranteed by epochs, the second cannot be guaranteed
under a wedged-node fault without an external fence.

- **I1a. Authoritative ownership is exclusive, always.** At every revision, each replica id has at
  most one assignment, and at most one tenure under which an observation of it is admissible. No
  fault exempts this: it is enforced by the store's compares.
- **I1b. Physical execution is exclusive outside the stated window.** A replaced replica's old
  instance and its replacement do not run at the same time for longer than `lost_grace_ms` plus
  kill latency, provided the node is not wedged and clock-rate skew is within bound. Under a wedged
  node the simulation records the overlap and does not count it as a violation for stateless
  replicas; for stateful ones (C7) only an external fence closes it.
- **I2.** No transaction commits whose tenure or placement epoch was superseded.
- **I3.** No decision cites an inadmissible observation as its cause.
- **I4.** Every key changed by a transaction was written by its prefix's writer role (§2).
- **I5.** Every `why` answer is `complete` or names its truncation (§5).
- **I6. Resource allocation is conserved.** Every committed placement or release changes the
  node's allocation record exactly once, by exactly the replica's `requests`; at every revision
  `/allocations/<node>.allocated` equals the sum of the `requests` of `/assigned/<node>/*`; and no
  committed placement leaves a node's allocation above its declared capacity.

The negative test, with skew beyond the bound or a wedged node, must find I1b violated, and a
scheduler variant that skips the allocation compare must find I6 violated. That is how we know
the simulation can see the failures the rules exclude. That is how
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

1. **Roots.** For each live subject, its newest decision **of each action**. A service's latest
   `apply` is therefore always a root, however many `replace_replica` decisions follow it; pinning
   only the newest decision would not protect the `apply`, because a crash loop's chain ends at an
   observation and never passes through it.
2. **Pinned.** A retention pass walks each root's chain to its terminal (the same walk as `why`,
   bounded by `why`'s depth limit) and pins every decision on it.
3. **Evictable.** A decision beyond the per-subject budget (newest 200, at most 7 days) **and not
   pinned**.
4. **Deleted subjects.** A deleted subject's decisions are no longer roots, but stay 24 hours.

The cost is one chain walk per live subject per pass. Chains are short (the C0 demo's are 2 to 5
steps), and a pass already works a page at a time.

### Decisions are immutable; repetition is counted beside them

**A decision never changes after it is written.** A later decision that cites it must find what
the controller saw when it acted. A decision updated in place to summarise later occurrences would
change the ancestor of every decision that already cites it, and `why` would no longer reconstruct
the justification at the time.

Repetition is counted in a **summary record**, `/decision-summaries/<kind>/<name>/<action>/<cause-kind>`,
for example `/decision-summaries/service/hello/replace_replica/observed`:

- it holds `count`, `first_at_ms`, `last_at_ms` and the id of the newest decision it counts;
- the actor updates it in the same transaction as each decision it counts, so it is exact;
- it is a **projection over decisions, never a cause**: no decision cites it, and `why` shows it
  next to a chain ("replaced 142 times since 14:02"), not as a step of one.

The decisions themselves remain, and retention removes old ones as above. A crash loop evicts its
own older `replace_replica` decisions, never the service's `apply` (a root). Any chain that needed
an evicted decision reports `truncated` with reason `retention`, while the summary still says how
many there were.

The cost is one decision per action, as now, plus one summary record per (subject, action, kind of
cause).

## 6. What C1 builds from this, and what it does not

**Built in C1:**

- the split of §2 (`/assigned/<node>/`, `/allocations/<node>`, `/node-status/<node>`, the node
  controller);
- the read-set rule;
- tenure compares on the agent endpoint;
- the `tenure` and `assignment` fields on observed records;
- agent self-fencing with a persisted `CLOCK_BOOTTIME` deadline;
- `lost_grace_ms`;
- `sim-c1` with I1a, I1b and I2 to I6;
- `completeness` in `why`;
- reachability-based retention, with a root per subject and action;
- `/allocations/<node>` and the placement and release transactions that maintain it;
- `/decision-summaries/`, with decisions immutable.

`demo-c1` shows the fencing window: the partition test of HANDOFF's acceptance criteria.

**Recorded, not built:**

- the C7 fencing proofs and epoch-checked durable writes;
- controller leadership for a second server;
- the TLA+ model.

**Follow-ups to this document once C1 lands:** keys.md takes the new prefixes and fields, api.md
takes `completeness`, and console.md shows it.
