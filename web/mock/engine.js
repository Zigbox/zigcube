// A small simulation of the Zigcube control plane: a versioned key-value store (docs/keys.md),
// the controllers that write decisions, and node agents that write observed state. It exists so
// the console can be built and demonstrated before the server does. It is deliberately not a
// faithful copy of the real controllers; it produces data of the right shape, with causes.
//
// Time is virtual: `advance(ms)` moves it, a ticker in the transport drives it in real time, and
// the scenario runner can fast-forward. Nothing here touches the DOM.

import {
  KNOWN_IMAGES, NODE_CAPACITY, LEASE_TTL_MS, diagImageNotFound, diagStoreDown, digestShort,
} from "./fixtures.js";

const STEP_MS = 250;
const START_DELAY_MS = 700;
const DEFAULT_REQUEST = { cpu_millis: 250, memory_bytes: 134217728 };

export class StoreDown extends Error {}

export class Engine {
  constructor({ backend = "postgres" } = {}) {
    this.backend = backend;
    this.base = Date.now();
    this.t = 0;
    this.rev = 0;
    this.compacted = 0;
    this.versions = new Map(); // key -> [{rev, value|null, create, lease}]
    this.history = []; // [{rev, type, key}] for watches
    this.waiters = new Set();
    this.leases = new Map();
    this.nextLease = 40;
    this.storeUp = true;
    this.downSince = 0;
    this.tasks = [];
    this.agents = new Map();
    this.seenNodes = new Map(); // node -> lease id, for the node controller
    this.everSeen = new Set();
    this.decisionCounter = 0;
    this.held = new Set(); // observed revisions already explained by a hold decision
    this.activeUntil = 0;
    this.dirty = true;
    this.requestSeq = 0;
  }

  now() { return this.base + this.t; }

  // ---- The store ---------------------------------------------------------------------------

  requireUp() { if (!this.storeUp) throw new StoreDown(); }

  current(key, at = this.rev) {
    const list = this.versions.get(key);
    if (!list) return null;
    for (let i = list.length - 1; i >= 0; i--) if (list[i].rev <= at) return list[i].value === null ? null : list[i];
    return null;
  }

  kvOf(key, v) { return { key, value: v.value, create_revision: v.create, mod_revision: v.rev, lease: v.lease }; }

  get(key) { const v = this.current(key); return v ? v.value : null; }
  getKv(key) { const v = this.current(key); return v ? this.kvOf(key, v) : null; }

  list(prefix, { at = this.rev, reverse = false, limit = 500, after = null } = {}) {
    const out = [];
    for (const key of this.versions.keys()) {
      if (!key.startsWith(prefix)) continue;
      const v = this.current(key, at);
      if (v) out.push(this.kvOf(key, v));
    }
    out.sort((a, b) => (a.key < b.key ? -1 : 1));
    if (reverse) out.reverse();
    const start = after ? out.findIndex(kv => kv.key === after) + 1 : 0;
    const page = out.slice(start, start + limit);
    return { kvs: page, more: start + limit < out.length, last: page.length ? page[page.length - 1].key : null };
  }

  values(prefix) { return this.list(prefix, { limit: 100000 }).kvs.map(kv => kv.value); }

  /** One transaction, one revision. ops: {put:[key, value, lease?]} | {del:key}. */
  commit(ops) {
    this.requireUp();
    const effective = ops.filter(op => op.put || this.current(op.del));
    if (!effective.length) return this.rev;
    const rev = ++this.rev;
    for (const op of effective) {
      const key = op.put ? op.put[0] : op.del;
      const list = this.versions.get(key) || [];
      const prev = this.current(key, rev - 1);
      if (op.put) {
        list.push({ rev, value: op.put[1], create: prev ? prev.create : rev, lease: op.put[2] || 0 });
        if (op.put[2]) this.leases.get(op.put[2])?.keys.add(key);
      } else {
        list.push({ rev, value: null });
        if (prev?.lease) this.leases.get(prev.lease)?.keys.delete(key);
      }
      this.versions.set(key, list);
      this.history.push({ rev, type: op.put ? "put" : "delete", key });
    }
    this.dirty = true;
    for (const wake of [...this.waiters]) wake();
    return rev;
  }

  compact(rev = this.rev) {
    this.compacted = Math.max(this.compacted, Math.min(rev, this.rev));
    this.history = this.history.filter(e => e.rev > this.compacted);
    for (const [key, list] of this.versions) {
      const keep = list.filter(v => v.rev > this.compacted);
      const before = list.filter(v => v.rev <= this.compacted).pop();
      if (before && before.value !== null) keep.unshift(before);
      if (keep.length) this.versions.set(key, keep); else this.versions.delete(key);
    }
  }

  /** Events at or after `from` for any of the prefixes, and the bookmark revision. */
  eventsFrom(prefixes, from) {
    const events = this.history
      .filter(e => e.rev >= from && prefixes.some(p => e.key.startsWith(p)))
      .map(e => {
        const v = (this.versions.get(e.key) || []).find(x => x.rev === e.rev);
        const value = v && v.value !== null ? v.value : null;
        return { type: e.type, kv: { key: e.key, value, create_revision: v?.create ?? 0, mod_revision: e.rev, lease: v?.lease || 0 } };
      });
    return { events, revision: this.rev };
  }

  // ---- Time and tasks ----------------------------------------------------------------------

  after(ms, fn) { this.tasks.push({ at: this.t + ms, fn }); this.activeUntil = Math.max(this.activeUntil, this.t + ms + STEP_MS); }

  advance(ms) {
    let left = ms;
    while (left > 0) {
      const dt = Math.min(left, STEP_MS);
      left -= dt;
      this.t += dt;
      this.step();
    }
  }

  step() {
    const due = this.tasks.filter(task => task.at <= this.t);
    this.tasks = this.tasks.filter(task => task.at > this.t);
    for (const task of due) {
      try { if (task.fn() === false) this.after(500, task.fn); } catch (e) { if (!(e instanceof StoreDown)) throw e; this.after(500, task.fn); }
    }
    if (!this.storeUp) return;
    for (const agent of this.agents.values()) this.agentTick(agent);
    this.expireLeases();
    if (this.dirty) { this.dirty = false; this.reconcile(); }
  }

  settled() { return this.t >= this.activeUntil && !this.tasks.length && !this.dirty; }

  settle(limitMs = 60000) {
    const end = this.t + limitMs;
    while (!this.settled() && this.t < end) this.advance(STEP_MS);
  }

  setStoreUp(up) {
    if (up === this.storeUp) return;
    if (!up) { this.storeUp = false; this.downSince = this.t; for (const wake of [...this.waiters]) wake(); return; }
    const gap = this.t - this.downSince;
    for (const lease of this.leases.values()) lease.deadline += gap; // lease clocks pause with the store
    this.storeUp = true;
    this.dirty = true;
  }

  // ---- Leases ------------------------------------------------------------------------------

  grant(ttl) {
    const lease = { id: ++this.nextLease, ttl, deadline: this.t + ttl, keys: new Set() };
    this.leases.set(lease.id, lease);
    return lease;
  }

  expireLeases() {
    for (const lease of [...this.leases.values()]) {
      if (lease.deadline > this.t) continue;
      this.leases.delete(lease.id);
      this.commit([...lease.keys].map(key => ({ del: key })));
    }
  }

  // ---- Decisions ---------------------------------------------------------------------------

  /** Builds a decision plus the index op that must be committed with it. */
  decision({ actor, action, subject, reason, cause, causeDiagnostic }) {
    const at = this.now();
    const id = `${String(at).padStart(13, "0")}-rc01-${String(++this.decisionCounter).padStart(4, "0")}`;
    const value = { v: 1, id, at_ms: at, actor, action, subject, reason, cause };
    if (causeDiagnostic) value.cause_diagnostic = causeDiagnostic;
    return {
      id,
      ops: [
        { put: [`/decisions/${id}`, value] },
        { put: [`/decisions-by-subject/${subject.kind}/${subject.name}/${id}`, { v: 1, id, at_ms: at, action, summary: reason }] },
      ],
    };
  }

  // ---- API-level writes (what `zcube apply` does) ------------------------------------------

  apply(spec, { actor = "alex@laptop", requestId = this.newRequestId() } = {}) {
    this.requireUp();
    const key = `/services/${spec.name}`;
    const existing = this.getKv(key);
    const same = existing && ["image", "command", "env", "limits"].every(k => JSON.stringify(existing.value[k]) === JSON.stringify(spec[k] ?? (k === "env" ? [] : k === "limits" ? {} : undefined)));
    const value = {
      v: 1, name: spec.name, image: spec.image, replicas: spec.replicas, command: spec.command,
      env: spec.env || [], limits: spec.limits || {},
      // A change of the replica count alone does not bump the generation here; keys.md is silent on it.
      generation: existing ? existing.value.generation + (same ? 0 : 1) : 1,
      next_replica: existing ? existing.value.next_replica : 1,
      applied_by: actor, request_id: requestId, // proposed additions to /services/<name>, see docs/api.md
    };
    this.commit([{ put: [key, value] }]);
    return value;
  }

  newRequestId() { return "r-" + (++this.requestSeq).toString(16).padStart(6, "0") + Math.floor(Math.random() * 0xfff).toString(16); }

  // ---- Controllers -------------------------------------------------------------------------

  reconcile() {
    this.nodeController();
    for (const svc of this.values("/services/")) this.serviceController(svc);
  }

  nodeController() {
    const nodes = new Map(this.list("/nodes/").kvs.map(kv => [kv.value.name, kv]));
    for (const [name, kv] of nodes) {
      if (this.seenNodes.get(name) === kv.lease) continue;
      const rejoin = this.everSeen.has(name);
      this.everSeen.add(name);
      this.seenNodes.set(name, kv.lease);
      const joined = this.decision({
        actor: "node-controller", action: "node_joined", subject: { kind: "node", name },
        reason: `node ${name} registered with lease ${kv.lease} (ttl ${LEASE_TTL_MS / 1000} s)`,
        cause: { kind: "observed", key: kv.key, revision: kv.mod_revision },
      });
      const ops = [...joined.ops];
      const others = this.values("/replicas/").filter(r => r.node && r.node !== name).length;
      if (rejoin && others > 0) {
        ops.push(...this.decision({
          actor: "scheduler", action: "skip_rebalance", subject: { kind: "node", name },
          reason: `${name} rejoined with no replicas while ${others} run on other nodes; moving running replicas back would restart them, and rebalancing is off by default`,
          cause: { kind: "decision", id: joined.id },
        }).ops);
      }
      this.commit(ops);
    }
    for (const [name, lease] of [...this.seenNodes]) {
      if (nodes.has(name)) continue;
      this.seenNodes.delete(name);
      this.lostLease = this.lostLease || {};
      const d = this.decision({
        actor: "node-controller", action: "node_lost", subject: { kind: "node", name },
        reason: `node ${name} stopped renewing lease ${lease} for ${LEASE_TTL_MS / 1000} s, so its registration was deleted`,
        cause: { kind: "lease_expired", key: `/nodes/${name}`, lease, ttl_ms: LEASE_TTL_MS, revision: this.rev },
      });
      this.lostLease[name] = d.id;
      this.commit(d.ops);
    }
  }

  observedOf(r) { return r.node ? this.get(`/observed/${r.node}/${r.id}`) : null; }

  serviceController(svc) {
    const replicas = this.values(`/replicas/${svc.name}/`);
    const svcKv = this.getKv(`/services/${svc.name}`);
    const live = [];
    const removed = [];
    let ops = [];
    const nodeKeys = new Set(this.list("/nodes/").kvs.map(kv => kv.value.name));

    for (const r of replicas) {
      const obs = this.observedOf(r);
      if (r.node && !nodeKeys.has(r.node)) {
        const lostId = this.lostLease?.[r.node];
        const d = this.decision({
          actor: "replica-controller", action: "mark_replica_lost", subject: { kind: "replica", name: r.id },
          reason: `node ${r.node} is gone, so ${r.id} can no longer be running there`,
          cause: lostId ? { kind: "decision", id: lostId } : { kind: "resync" },
        });
        ops.push(...d.ops, { del: `/replicas/${svc.name}/${r.id}` });
        removed.push({ replica: r, decisionId: d.id, why: `${r.id} was lost with node ${r.node}` });
      } else if (obs && obs.status === "stopped") {
        const obsKv = this.getKv(`/observed/${r.node}/${r.id}`);
        const userFault = obs.exit.kind === "start_failed" && obs.diagnostic?.blame === "user";
        if (userFault) {
          live.push(r);
          const tag = `${obsKv.key}@${obsKv.mod_revision}`;
          if (!this.held.has(tag)) {
            this.held.add(tag);
            ops.push(...this.decision({
              actor: "replica-controller", action: "hold_failed_replica", subject: { kind: "service", name: svc.name },
              reason: `replica ${r.id} failed to start on ${r.node}; it was not replaced because a new one would fail the same way`,
              cause: { kind: "observed", key: obsKv.key, revision: obsKv.mod_revision },
              causeDiagnostic: obs.diagnostic,
            }).ops);
          }
        } else {
          const d = this.decision({
            actor: "replica-controller", action: "delete_replica", subject: { kind: "replica", name: r.id },
            reason: `${r.id} ${this.exitText(obs.exit)} on ${r.node}, so it is being removed`,
            cause: { kind: "observed", key: obsKv.key, revision: obsKv.mod_revision },
            causeDiagnostic: obs.diagnostic,
          });
          ops.push(...d.ops, { del: `/replicas/${svc.name}/${r.id}` });
          removed.push({ replica: r, decisionId: d.id, why: `${r.id} ${this.exitText(obs.exit)}` });
        }
      } else live.push(r);
    }

    const want = svc.replicas;
    let next = svc.next_replica;
    const baseCause = removed.length
      ? { kind: "decision", id: removed[0].decisionId }
      : { kind: "desired", key: svcKv.key, revision: svcKv.mod_revision };

    if (live.length < want) {
      const n = want - live.length;
      const action = removed.length ? "replace_replica" : "scale_up";
      const reason = removed.length
        ? `service ${svc.name} wants ${want} ${want === 1 ? "replica" : "replicas"} and ${live.length} remain (${removed.map(x => x.why).join("; ")})`
        : `service ${svc.name} wants ${want} ${want === 1 ? "replica" : "replicas"} and ${live.length} exist`;
      const sd = this.decision({ actor: "replica-controller", action, subject: { kind: "service", name: svc.name }, reason, cause: baseCause });
      ops.push(...sd.ops);
      const placing = this.placementState();
      for (let i = 0; i < n; i++) {
        const id = `${svc.name}-${next++}`;
        const create = this.decision({
          actor: "replica-controller", action: "create_replica", subject: { kind: "replica", name: id },
          reason: `creating ${id} (generation ${svc.generation}) for service ${svc.name}`,
          cause: { kind: "decision", id: sd.id },
        });
        const placed = this.place(svc, placing, create.id, id);
        const replica = { v: 1, id, service: svc.name, generation: svc.generation, node: placed ? placed.node : "", image: svc.image, command: svc.command, env: svc.env, limits: svc.limits };
        ops.push(...create.ops, { put: [`/replicas/${svc.name}/${id}`, replica] });
        if (placed) ops.push(...placed.ops);
      }
    } else if (live.length > want) {
      const victims = [...live].sort((a, b) => this.rank(a) - this.rank(b) || this.num(b.id) - this.num(a.id)).slice(0, live.length - want);
      const sd = this.decision({
        actor: "replica-controller", action: "scale_down", subject: { kind: "service", name: svc.name },
        reason: `service ${svc.name} wants ${want} ${want === 1 ? "replica" : "replicas"} and ${live.length} exist; removing ${victims.map(v => v.id).join(", ")}`,
        cause: baseCause,
      });
      ops.push(...sd.ops);
      for (const v of victims) {
        ops.push(...this.decision({
          actor: "replica-controller", action: "delete_replica", subject: { kind: "replica", name: v.id },
          reason: `removing ${v.id} to get from ${live.length} to ${want} ${want === 1 ? "replica" : "replicas"}`, cause: { kind: "decision", id: sd.id },
        }).ops, { del: `/replicas/${svc.name}/${v.id}` });
      }
    }

    if (next !== svc.next_replica) ops.push({ put: [`/services/${svc.name}`, { ...svc, next_replica: next }] });
    if (ops.length) this.commit(ops);
  }

  rank(r) { const o = this.observedOf(r); return o && o.status === "running" ? 1 : 0; } // stop the not-running ones first
  num(id) { return Number(id.slice(id.lastIndexOf("-") + 1)); }
  exitText(exit) {
    switch (exit.kind) {
      case "exited": return `exited with code ${exit.code}`;
      case "signaled": return `was killed by signal ${exit.signal}${exit.signal === 9 ? " (SIGKILL)" : ""}`;
      case "oom": return "ran out of memory";
      case "pid_limit": return "hit its process limit";
      case "start_failed": return "failed to start";
      default: return "was lost";
    }
  }

  // ---- Scheduler ---------------------------------------------------------------------------

  placementState() {
    const nodes = this.list("/nodes/").kvs.map(kv => kv.value);
    const replicas = this.values("/replicas/");
    return { nodes, replicas: [...replicas] };
  }

  place(svc, state, causeId, replicaId) {
    const used = name => state.replicas.filter(r => r.node === name).reduce((a, r) => ({
      cpu: a.cpu + (r.limits.cpu_millis ?? DEFAULT_REQUEST.cpu_millis),
      mem: a.mem + (r.limits.memory_bytes ?? DEFAULT_REQUEST.memory_bytes),
    }), { cpu: 0, mem: 0 });
    const need = { cpu: svc.limits.cpu_millis ?? DEFAULT_REQUEST.cpu_millis, mem: svc.limits.memory_bytes ?? DEFAULT_REQUEST.memory_bytes };
    const fits = state.nodes.filter(n => { const u = used(n.name); return u.cpu + need.cpu <= n.capacity.cpu_millis && u.mem + need.mem <= n.capacity.memory_bytes; });
    if (!fits.length) return null;
    const count = name => state.replicas.filter(r => r.node === name && r.service === svc.name).length;
    fits.sort((a, b) => count(a.name) - count(b.name) || (a.name < b.name ? -1 : 1));
    const pick = fits[0];
    const counts = fits.map(n => `${n.name} ${count(n.name)}`).join(", ");
    const id = state.nextId = (state.nextId || 0) + 1;
    state.replicas.push({ id: "pending-" + id, service: svc.name, node: pick.name, limits: svc.limits });
    const reason = state.nodes.length === 1
      ? `${pick.name} is the only node, and it fits ${need.cpu}m CPU and ${Math.round(need.mem / 1048576)} MiB`
      : `${pick.name} has the fewest ${svc.name} replicas of the ${fits.length} nodes that fit (${counts})`;
    const d = this.decision({ actor: "scheduler", action: "place_replica", subject: { kind: "replica", name: replicaId }, reason, cause: { kind: "decision", id: causeId } });
    return { node: pick.name, ops: d.ops };
  }

  // ---- Agents ------------------------------------------------------------------------------

  addAgent(name, { capacity = NODE_CAPACITY, on = true } = {}) {
    const agent = { name, up: false, capacity, address: `10.0.0.${5 + this.agents.size}:7070`, lease: null, starting: new Set() };
    this.agents.set(name, agent);
    if (on) this.powerOn(name);
    return agent;
  }

  powerOn(name) { const a = this.agents.get(name); a.up = true; a.lease = null; this.dirty = true; this.activeUntil = Math.max(this.activeUntil, this.t + 2000); }
  powerOff(name) {
    const a = this.agents.get(name);
    a.up = false;
    if (a.lease) this.activeUntil = Math.max(this.activeUntil, a.lease.deadline + 3000);
  }

  agentTick(a) {
    if (!a.up) return;
    if (!a.lease || !this.leases.has(a.lease.id)) {
      a.lease = this.grant(LEASE_TTL_MS);
      this.commit([{ put: [`/nodes/${a.name}`, { v: 1, name: a.name, agent_version: "0.0.0", address: a.address, capacity: a.capacity, labels: [] }, a.lease.id] }]);
    } else a.lease.deadline = this.t + a.lease.ttl; // keepalive: not a revision

    const mine = this.list("/replicas/").kvs.map(kv => kv.value).filter(r => r.node === a.name);
    const ids = new Set(mine.map(r => r.id));
    for (const r of mine) {
      if (this.get(`/observed/${a.name}/${r.id}`) || a.starting.has(r.id)) continue;
      a.starting.add(r.id);
      this.commit([{ put: [`/observed/${a.name}/${r.id}`, this.observed(a, r, "starting")] }]);
      this.after(START_DELAY_MS, () => {
        a.starting.delete(r.id);
        if (!a.up || !this.get(`/replicas/${r.service}/${r.id}`)) return;
        if (KNOWN_IMAGES.has(r.image)) this.commit([{ put: [`/observed/${a.name}/${r.id}`, this.observed(a, r, "running")] }]);
        else this.commit([{ put: [`/observed/${a.name}/${r.id}`, this.observed(a, r, "stopped", { kind: "start_failed" }, diagImageNotFound(r.image, a.name, r.id))] }]);
      });
    }
    const orphans = this.list(`/observed/${a.name}/`).kvs.filter(kv => !ids.has(kv.value.replica));
    if (orphans.length) this.commit(orphans.map(kv => ({ del: kv.key }))); // stop what no longer has a desired replica
  }

  observed(a, r, status, exit, diagnostic) {
    const value = { v: 1, replica: r.id, node: a.name, generation: r.generation, status, reported_at_ms: this.now() };
    if (exit) value.exit = exit;
    if (diagnostic) value.diagnostic = diagnostic;
    return value;
  }

  /** Simulates `kill -9` of a replica's process on its node. */
  kill(replicaId) {
    const r = this.values("/replicas/").find(x => x.id === replicaId);
    if (!r) return false;
    const a = this.agents.get(r.node);
    this.commit([{ put: [`/observed/${r.node}/${r.id}`, this.observed(a, r, "stopped", { kind: "signaled", signal: 9 })] }]);
    return true;
  }

  runningReplicas(service) {
    return this.values(`/replicas/${service}/`).filter(r => this.observedOf(r)?.status === "running").map(r => r.id);
  }

  storeDiagnostic() { return diagStoreDown(this.backend); }
  short(d) { return digestShort(d); }
}
