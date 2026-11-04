# Input: Botpike, the first customer

Owner, 2026-11-04: Botpike (budget leases for AI agents, `Botpike/app`) moves its agent runs onto
Zigcube and drops its own runtime. Zigcube's roadmap after C2 is reordered with Botpike's needs
first (docs/decisions/2026-11-04-botpike-first-customer.md). This is a list of requirements to fold
into the briefs of the milestones it touches (C8, C4, C6, and placement), not a brief. Every
Zigcube fact below names its file; every Zigbox fact names its file or its brief. I read the code
of both at `main` on 2026-11-04 (Zigcube `2d9d511`, Zigbox `6838c87`) and the M8 brief on Zigbox's
branch `claude/m8-brief` (PR #54). I ran nothing.

Botpike's side is specified in `Botpike/app`, `docs/specs/runs-on-zigcube/` (the broker, the
runtime port, admission, and the ledger as the record). Only what Zigcube and Zigbox must provide
is here.

## Why Botpike fits, and what it needs

Botpike's promise is *if Botpike did not authorize it, it did not happen*. A run is an agent
program (any language, a customer's or Botpike's own image) that spends money by calling models,
reading web pages and paying for things. Every one of those calls must pass Botpike's **broker**,
which reserves the money in the ledger (Nerva) before the call and settles it after.

So the gate is the network boundary, not the language. Botpike needs Zigcube to run an untrusted
image so that:

1. its **only** way out is the broker, with no DNS, no metadata address, no peers and no host;
2. it holds **no credential**: the broker learns who is calling from the node, never from the
   workload;
3. it runs to completion under a deadline, can be cancelled, and reports how it ended;
4. it runs only if its image carries a signature the cluster trusts;
5. one customer's runs share a node only with that customer's runs, until microVM isolation
   exists.

Items 1 and 2 are a narrow slice of C4 (Mesh), 3 is C8 (Jobs) without gang scheduling or builds,
4 is a slice of C6 (Trust), and 5 is a placement constraint. None of them is Botpike-specific:
each is the general feature, cut to what a first customer needs, and every name below is
Zigcube's, not Botpike's.

## B1 · Jobs (from C8)

**What.** A `job` object beside `service`: run one task to completion.

- **Fields:** `name`, `image` (tree digest), `source`, `command`, `env`, `limits` (as
  `Runtime.Spec`, `src/runtime.zig:94`), `deadline_ms`, `retries` (Botpike always sends 0: a
  retry would spend again), `relay` (B2, optional), `placement` (B5, optional), and `labels`:
  client-supplied pairs that Zigcube stores, copies into the workload identity (B3) and never
  interprets (Botpike sends `run`, `org`).
- **States:** `pending → admitted | refused → placed → running → exited | failed | cancelled`.
  `exited` carries the exit code; `failed` carries a cause from a closed set: `oom`, `pid_limit`,
  `deadline`, `node_lost`, `start_failed`, `refused` (with the C6 cause). Each transition is a
  decision record, so `zcube why job <name>` answers.
- **API:** `POST /v1/jobs` (idempotent on `name`: the same body again is a no-op, a different
  body under the same name is refused), `GET /v1/jobs/{name}`, `POST /v1/jobs/{name}/cancel`
  (stop with a grace period, then kill; cancelling a finished job is a no-op that returns its end),
  and a watch over jobs from a revision, gap-free like the store's (`docs/store-design.md`), so a
  client that restarts resumes from the last revision it saw and misses no ending.
- **Retention:** a finished job is kept for a bounded time and count (both constants, asserted),
  then compacted. Botpike copies what it needs on the ending event.
- **Logs:** the last N KiB of a job's output, readable through the API until compaction
  (`zbx logs` keeps 5 MiB per container already, M6b). Botpike shows it on the run page; it is
  never used to decide an outcome.
- **Bounded:** at most `jobs_max` jobs not yet finished in the cluster and `jobs_per_node_max` per
  node; a job over either waits in `pending` with the reason in `why`.

**Not needed now:** gang scheduling, M7 build dispatch, the shared build cache. Those stay in C8.

**Acceptance.**

- A job that exits 0, one that exits 3, one killed by OOM, one past its deadline and one
  cancelled each end in the right state with the right cause, and a watcher that restarts in the
  middle sees every ending exactly once.
- `kill -9` of `zcube-agent` while a job runs: the job keeps running (supervisor, as for
  services) and its ending is reported after the agent restarts. Loss of the node: `failed`,
  `node_lost`, once the node's lease expires, and the job is **not** started elsewhere when
  `retries` is 0.
- `sim-cluster` gains jobs, and the C1 checks hold for them: no job runs on two nodes at once, an
  ended job never runs again.

## B2 · The relay: a workload's only route (a slice of C4)

**What.** A network mode, `relay`, for a workload that may talk to exactly one upstream, named in
cluster configuration (never in the API, so a compromised API client cannot point a relay
elsewhere): `relays = .{ .botpike = .{ .address = "broker.botpike.com:8443" } }`, and the job
says `relay = "botpike"`.

Inside the workload:

- The network namespace has only `lo` (Zigbox `--net none`, `src/runtime/spec.zig:39-47`).
- One TCP listener on `127.0.0.1:<port>` (default 8080), whose other end is outside the
  workload. Every connection to it is relayed to the upstream. Nothing else answers: not DNS, not
  `169.254.169.254`, not the node's address, not another workload's listener.
- The workload is told the address through the environment (`ZCUBE_RELAY=http://127.0.0.1:8080`);
  Botpike also sets the model SDKs' base URLs to it.

On the node:

- `zcube-agent` (or one relay process per node that it supervises) owns the far end. It knows
  which workload each connection came from **by construction**, because each workload has its
  own listener. It never reads anything the workload sends to decide who the workload is.
- It opens a TLS connection to the upstream and presents the workload's identity (B3).
- Bounds: connections per workload, bytes per connection and idle time, each a constant,
  asserted, with a coded diagnostic when hit. Streams pass through unbuffered (model replies are
  server-sent events).

**Zigbox change needed** (to be asked of Zigbox; none is made from Zigcube): a way to hand the
supervisor a listening socket inside the container's network namespace. Proposed: with
`--net none --listen-fd 127.0.0.1:8080`, the single-threaded child that sets up namespaces
(AGENTS.md: all namespace work happens there) creates and binds the listener after `unshare`
and before `execve`, and passes the descriptor to the supervisor with `SCM_RIGHTS`. A socket keeps
the namespace it was created in, so the supervisor accepts connections inside the container's
namespace while staying outside it, and the workload cannot close or replace it (it is not in the
workload's descriptor table). The supervisor hands each accepted connection to the agent's relay.
No host firewall or routing change (M5's rule holds), no veth, no privilege.

The alternative, a host Unix socket bind-mounted read-only under `--net none` (M6), needs a
process inside the container to turn TCP into the socket. That puts a relay in the workload's
reach and in every image, so it is the fallback, not the plan.

**Acceptance (hostile, run from inside the workload by a test image):**

- `connect` to `1.1.1.1:443`, to the node's own address, to `169.254.169.254:80`, to
  `zcube-server`, and to another workload's relay port: each fails.
- A DNS lookup of any name fails.
- A raw or packet socket cannot be opened (seccomp and the capability set already refuse it;
  the test proves it for this mode).
- A request to the relay arrives at a test upstream carrying the identity of the job that sent
  it, and only that job's.
- After the job ends, its listener is gone and its identity is refused by the upstream (B3).

## B3 · Workload identity on the relay (a slice of C4)

**What.** The relay proves to the upstream which workload is calling. The identity is the one
C4 already decided (docs/decisions/2026-10-27-c4-workload-identity-binds-service-image.md):
the object (here the job's name), the image digest and the placement epoch, plus the job's
`labels`, so that Botpike reads its run and org from it.

**The format must be checkable by a stock TLS stack**, because the upstream is a JVM service:
an **X.509 certificate with an Ed25519 key, carrying a SPIFFE ID** (`spiffe://<cluster>/job/<name>`
in the URI SAN; SPEC Part II's risk row names SPIFFE), with the digest, epoch and labels in a
private extension. It is issued by the cluster CA (`docs/peer.md`), for the job's lifetime: not
after `deadline_ms` plus a small constant, renewed never. Botpike pins the cluster CA's
certificate.

**Mechanism.** The relay is the TLS **client** and presents the workload's certificate (mTLS).
The workload never holds the key. This needs a TLS 1.3 client with a client certificate; the
pinned std has a client but no client certificates (`docs/peer.md:4`). The client side is a
smaller piece of the in-house TLS work than the server (which B6 needs), so it can come first.

**Interim, only if the client-certificate work slips:** the relay speaks HTTP/1.1 to the
upstream over std's TLS client (server authentication only), one request per connection, strips
any `Zcube-` header the workload sent, and adds `Zcube-Identity: <token>`: the identity fields,
an expiry and a nonce, signed by the node's Ed25519 key, followed by the node's CA-signed
credential (`docs/peer.md`, the 185-byte credential). Botpike verifies it against the CA's public
key. Owner question O2 decides whether to allow the interim at all.

**Acceptance.**

- The test upstream (a stock TLS server configured with the CA certificate) accepts the relay's
  connection and reads the job, digest, epoch and labels from the certificate.
- A certificate for another job, an expired one, one from another CA, and a connection with no
  certificate are refused by the test upstream. (This tests the format, not Botpike.)
- The workload cannot read its key: the key never enters the container's mount namespace.
- Revocation: cancelling a job ends its relay connections within a bounded time, and since the
  certificate dies with the job's deadline, a stolen certificate is worth no more than the job.

## B4 · Signed images only (a slice of C6)

**What.** A job starts only from an image whose signature satisfies cluster policy, checked
twice: by `zcube-server` when the job is admitted, and by `zcube-agent` before exec, from a
node-local copy of the trusted keys that the API cannot change (SPEC Part II, C6). Both call
Zigbox's verdict function (`zigbox.trust`, M8 brief on `claude/m8-brief`): DSSE, in-toto
Statement v1, Ed25519, subject `{"zbxTree": "<hex>"}`.

Botpike's use is simple: **the cluster trusts one key, Botpike's admission key.** Customers' own
keys live in Botpike, which checks a customer's signature and then signs the tree digest itself.
So nothing a tenant controls ever changes node trust, and C6's "node trust cannot be changed
through the control plane" holds unchanged.

- A refusal is a job state (`refused`) with the M8 code and cause, never a start that fails
  later. It never stops anything already running.
- Botpike needs the tree digest of an image to sign it. Either Botpike runs `zbx pull` itself
  (its admission host has Zigbox), or Zigcube offers a "resolve" call that pulls an OCI reference
  and returns its tree digest without running it. Owner question O3.

**Acceptance.** An unsigned image, one signed by an untrusted key, and one whose signature names
another tree are each refused before any process starts, at the server, and again at the agent
when the server is bypassed (a test writes the assignment straight into the store).

## B5 · Placement by tenant

**What.** Node labels exist (accepted at registration, at most 8, `src/agent_api.zig:680`) but
the scheduler never reads them (order: fit, spread, locality, least allocated, name;
`docs/briefs/c2.md:354`). Botpike needs:

- `placement.require = { "tenant": "<org>" }` on a job: only nodes with every listed label are
  candidates. No match means `pending` with the reason, never a start elsewhere.
- A node labelled `exclusive = "tenant"` takes only jobs whose `require` names its `tenant`
  value. A job with no `require` never lands there.
- `zcube why job` names the constraint when it decides.

Until Zigbox S1 (microVM) exists, Botpike gives each customer org its own small pool of nodes.
CS3 (tenant isolation on microVMs) later lets tenants share nodes again.

**Acceptance.** In `sim-cluster` and the demo, a job with `require` never runs on a node without
the labels, and an exclusive node never runs another tenant's job, across node loss and
re-registration.

## B6 · Who may call the API

`zcube-server`'s writes are unauthenticated (`docs/api.md:231`, `docs/agent.md`, "Known
limits"). Botpike's app will create and cancel jobs from the internet side of a private link.
Needed: a client identity for the API (mTLS with a certificate from the cluster CA, the same
in-house TLS work, server side), with a scope that allows jobs and nothing else: no services, no
node registration, no policy. Until the TLS server exists, an owner-approved interim (a TLS
front and a scoped bearer key) or a private network only. Owner question O4.

## Proposed order

Each step is demonstrable by itself; Botpike's spec set follows the same order.

| Step | What | Depends on |
|---|---|---|
| 1 | B1 Jobs | C2 shipped |
| 2 | B2 Relay | B1; the Zigbox `--listen-fd` change |
| 3 | B3 Identity (mTLS client side) | B2; the in-house TLS client with certificates |
| 4 | B4 Signed images | B1; Zigbox M8 merged and released |
| 5 | B5 Placement by tenant | B1 |
| 6 | B6 API identity | the in-house TLS server |

C3 (Rollout) and C5 (Edge) wait behind these. C3's simulation-fleet slices (`c3-sim-fleet.md`)
can run beside them, and should, since B1 and B5 change the scheduler.

## The demo: `demo-b1` (or folded into `demo-c8`)

On three nodes, two labelled for tenant `a` (one exclusive) and one for tenant `b`, with a test
upstream standing in for Botpike's broker:

1. Submit a signed job for tenant `a` with `relay = "botpike"`. It runs on an `a` node. The
   test upstream logs one request carrying the job's identity, digest and labels.
2. The same job's image runs the hostile tests (B2). Each refusal prints and the job exits 0.
3. Submit an unsigned job: `refused`, with the M8 code, before any process starts.
4. Submit a job with a 2-second deadline that sleeps: `failed, deadline`. Cancel a running job:
   `cancelled`.
5. Power off the node running a tenant-`a` job: `failed, node_lost`, not restarted, and no `a`
   job ever lands on the `b` node.
6. Restart the watcher midway: it reports every ending exactly once.

## Owner questions

- **O1. Order.** Is the order above right, ahead of C3 and C5? (Recommended: yes. Botpike cannot
  launch runs without B1 to B5; C3 and C5 serve no customer yet.)
- **O2. Interim identity.** Allow B3's signed-header interim if the TLS client with certificates
  is not ready, or wait for mTLS? (Recommended: wait, if the client side is days away. The
  interim makes the relay parse HTTP, which mTLS avoids entirely.)
- **O3. Tree digests for signing.** Botpike runs `zbx pull` on its own admission host, or Zigcube
  gains a resolve call? (Recommended: Botpike runs `zbx pull`; it keeps Zigcube's API smaller.)
- **O4. API identity before the TLS server.** Private network only, or a TLS front with a scoped
  key? (Recommended: private network only. Botpike's app and Zigcube's server can share one.)
- **O5. Where nodes run.** Botpike's runs today were to run in Fly Machines (Firecracker VMs) in
  an organisation of their own. Zigbox needs unprivileged user namespaces, cgroup v2 with user
  delegation and `uidmap` (`zbx doctor`). Nobody has checked that a Fly Machine provides them.
  Check first, with `zbx doctor` on a Fly Machine, before B2's demo is planned around them.

## Non-goals here

Gang scheduling and build dispatch (C8 keeps them); service-to-service grants and the WireGuard
mesh (C4 keeps them); provenance and source-repository policy (C6 keeps them); microVM isolation
(Zigbox S1, Zigcube CS3); anything about money: Zigcube never learns what a run costs.
