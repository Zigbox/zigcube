// The console's copy of the cluster: list once, then follow the long-poll watch (docs/api.md).
// The data is a mirror of the store's keys; every view reads the derived selectors below, so a
// view never interprets a raw record on its own.

import { setClockOffset } from "./ui.js";

const PREFIXES = ["/services/", "/replicas/", "/nodes/", "/observed/", "/decisions/"];
const WATCH_TIMEOUT_MS = 25000;
const POLL_MS = 2000;
const STALE_AFTER_MS = 10000;
const DECISIONS_KEPT = 500;
const STORE_CODES = new Set(["ZC-E0201", "ZC-E0202"]);
const RELIST_CODES = new Set(["ZC-E0203", "ZC-E0204"]);

const sleep = (ms, signal) => new Promise(res => { const t = setTimeout(res, ms); signal?.addEventListener("abort", () => { clearTimeout(t); res(); }); });

export function exitText(exit) {
  if (!exit) return "";
  switch (exit.kind) {
    case "exited": return exit.code === 0 ? "exited cleanly" : `exited with code ${exit.code}`;
    case "signaled": return `killed by signal ${exit.signal}${exit.signal === 9 ? " (SIGKILL)" : exit.signal === 15 ? " (SIGTERM)" : ""}`;
    case "oom": return "out of memory";
    case "pid_limit": return "hit its process limit";
    case "start_failed": return "failed to start";
    default: return "lost without a known reason";
  }
}

export class Model {
  constructor(client) {
    this.client = client;
    this.listeners = new Set();
    this.reset();
    this.abort = new AbortController();
    this.stopped = false;
    this.log = [];
    this.error = null;
    this.relisting = false;
    this.loaded = false;
    this.lastOkAt = 0;
    this.leasePoll = { at: 0, byKey: new Map() };
    this.store = { ok: true, backend: "", diagnostic: null };
    this.version = 0;
    this.memo = new Map();
    this.pending = 0;
  }

  reset() {
    this.rev = 0;
    this.services = new Map();
    this.replicas = new Map();
    this.nodes = new Map();
    this.observed = new Map();
    this.decisions = new Map();
  }

  subscribe(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  changed() {
    this.version++;
    this.memo.clear();
    if (this.pending) return;
    this.pending = requestAnimationFrame(() => { this.pending = 0; for (const fn of [...this.listeners]) fn(); });
  }

  note(level, text, extra = {}) {
    this.log.unshift({ at: Date.now(), level, text, ...extra });
    this.log.length = Math.min(this.log.length, 40);
  }

  // ---- Connection state --------------------------------------------------------------------

  get connState() {
    if (!this.loaded && !this.error) return "connecting";
    if (this.error) {
      if (STORE_CODES.has(this.error.diagnostics[0].code)) return "stale";
      return Date.now() - this.error.since > STALE_AFTER_MS ? "stale" : "reconnecting";
    }
    return this.relisting ? "relisting" : "live";
  }

  // ---- Loop --------------------------------------------------------------------------------

  start() {
    this.run();
    this.poll();
  }
  stop() { this.stopped = true; this.abort.abort(); }

  async run() {
    let backoff = 1000;
    let needRelist = true;
    while (!this.stopped) {
      try {
        if (needRelist) { await this.relist(); needRelist = false; }
        await this.watchOnce(this.error ? 0 : WATCH_TIMEOUT_MS); // after a failure, probe with an immediate answer
        backoff = 1000;
      } catch (e) {
        if (e?.name === "AbortError" || this.stopped) return;
        if (e.code && RELIST_CODES.has(e.code)) {
          this.note("note", `The watch could not resume (${e.code}). Listing the current state again.`, { code: e.code });
          needRelist = true;
          this.relisting = true;
          this.changed();
          continue;
        }
        this.fail(e);
        await sleep(backoff, this.abort.signal);
        backoff = Math.min(backoff * 2, 3000);
      }
    }
  }

  fail(e) {
    if (!(e.diagnostics)) { console.error(e); return; }
    if (!this.error) this.note("error", `${e.diagnostics[0].code} ${e.diagnostics[0].summary}`, { code: e.diagnostics[0].code });
    this.error = { diagnostics: e.diagnostics, requestId: e.requestId, origin: e.origin, since: this.error?.since || Date.now() };
    this.changed();
  }

  ok() {
    this.lastOkAt = Date.now();
    if (this.error) { this.note("ok", "Connection restored."); this.error = null; }
    if (this.relisting && this.loaded) this.relisting = false;
    this.changed();
  }

  async listAll(prefix, at, extra = "", max = Infinity) {
    const kvs = [];
    let cont = null;
    for (;;) {
      const q = `/v1/list?prefix=${encodeURIComponent(prefix)}&limit=500${at ? `&at=${at}` : ""}${extra}${cont ? `&continue=${encodeURIComponent(cont)}` : ""}`;
      const { body } = await this.client.get(q, { signal: this.abort.signal });
      kvs.push(...body.kvs);
      if (!body.continue || kvs.length >= max) return { revision: body.revision, kvs };
      cont = body.continue;
    }
  }

  async relist() {
    const first = await this.listAll(PREFIXES[0], 0);
    const at = first.revision;
    const rest = await Promise.all([
      this.listAll("/replicas/", at), this.listAll("/nodes/", at), this.listAll("/observed/", at),
      this.listAll("/decisions/", at, "&reverse=true", DECISIONS_KEPT),
    ]);
    this.reset();
    for (const r of [first, ...rest]) for (const kv of r.kvs) this.put(kv);
    this.rev = at;
    const wasRelisting = this.relisting;
    if (wasRelisting) this.note("ok", `Listed the current state at revision ${at}; following changes from there.`);
    this.loaded = true;
    this.ok();
    this.relisting = false;
    this.changed();
  }

  async watchOnce(timeoutMs) {
    const qs = PREFIXES.map(p => `prefix=${encodeURIComponent(p)}`).join("&");
    const { body } = await this.client.get(`/v1/watch?${qs}&from=${this.rev + 1}&timeout=${timeoutMs}`, { signal: this.abort.signal });
    for (const ev of body.events) ev.type === "delete" ? this.remove(ev.kv.key) : this.put(ev.kv);
    this.rev = Math.max(this.rev, body.revision);
    this.ok();
  }

  async poll() {
    while (!this.stopped) {
      try {
        const [s, l] = await Promise.all([this.client.get("/v1/status", { signal: this.abort.signal }), this.client.get("/v1/leases", { signal: this.abort.signal })]);
        setClockOffset(s.body.time_ms - Date.now());
        this.store = { ...s.body.store };
        const byNode = new Map();
        for (const lease of l.body.leases) for (const key of lease.keys) byNode.set(key, lease);
        this.leasePoll = { at: Date.now(), byKey: byNode };
        this.changed();
      } catch (e) {
        if (e?.name === "AbortError") return;
        if (e.diagnostics && STORE_CODES.has(e.diagnostics[0].code)) this.store = { ok: false, diagnostic: e.diagnostics[0] };
      }
      await sleep(POLL_MS, this.abort.signal);
    }
  }

  put({ key, value, mod_revision, lease }) {
    const [, kind, a, b] = key.split("/");
    if (kind === "services") this.services.set(a, { value, mod: mod_revision });
    else if (kind === "replicas") this.replicas.set(b, { value, mod: mod_revision });
    else if (kind === "nodes") this.nodes.set(a, { value, mod: mod_revision, lease });
    else if (kind === "observed") this.observed.set(`${a}/${b}`, { value, mod: mod_revision, key });
    else if (kind === "decisions") {
      this.decisions.set(a, value);
      if (this.decisions.size > DECISIONS_KEPT + 50) {
        const keep = [...this.decisions.keys()].sort().slice(-DECISIONS_KEPT);
        this.decisions = new Map(keep.map(k => [k, this.decisions.get(k)]));
      }
    }
  }
  remove(key) {
    const [, kind, a, b] = key.split("/");
    if (kind === "services") this.services.delete(a);
    else if (kind === "replicas") this.replicas.delete(b);
    else if (kind === "nodes") this.nodes.delete(a);
    else if (kind === "observed") this.observed.delete(`${a}/${b}`);
    else if (kind === "decisions") this.decisions.delete(a);
  }

  // ---- Selectors ---------------------------------------------------------------------------

  memoized(name, fn) {
    if (!this.memo.has(name)) this.memo.set(name, fn());
    return this.memo.get(name);
  }

  replicaViews() {
    return this.memoized("replicas", () => {
      const out = [];
      for (const { value: r } of this.replicas.values()) {
        const obs = r.node ? this.observed.get(`${r.node}/${r.id}`)?.value : null;
        const registered = r.node ? this.nodes.has(r.node) : true;
        let state;
        if (!r.node) state = "unscheduled";
        else if (!registered) state = "lost";
        else if (!obs) state = "pending";
        else if (obs.status === "starting") state = "starting";
        else if (obs.status === "running") state = "running";
        else if (obs.exit?.kind === "exited" && obs.exit.code === 0) state = "stopped";
        else if (obs.exit?.kind === "lost") state = "lost";
        else state = "failed";
        let reason = "";
        if (state === "lost" && !registered) reason = `node ${r.node} is gone`;
        else if (obs?.status === "stopped") reason = exitText(obs.exit);
        else if (state === "unscheduled") reason = "no node assigned yet";
        out.push({ id: r.id, service: r.service, node: r.node, image: r.image, generation: r.generation, limits: r.limits || {}, state, reason, obs, diagnostic: obs?.diagnostic || null, reportedAt: obs?.reported_at_ms || 0, spec: r });
      }
      return out.sort((a, b) => (a.service < b.service ? -1 : a.service > b.service ? 1 : numOf(a.id) - numOf(b.id)));
    });
  }

  serviceViews() {
    return this.memoized("services", () => {
      const reps = this.replicaViews();
      return [...this.services.values()].map(({ value: spec, mod }) => {
        const mine = reps.filter(r => r.service === spec.name);
        const c = { running: 0, starting: 0, pending: 0, failed: 0, lost: 0, stopped: 0, unscheduled: 0 };
        for (const r of mine) c[r.state]++;
        const desired = spec.replicas;
        let health;
        if (desired === 0 && mine.length === 0) health = "idle";
        else if (c.running >= desired) health = "healthy";
        else if (c.running === 0) health = c.failed + c.lost ? "failing" : "converging";
        else health = c.failed + c.lost ? "degraded" : "converging";
        const bad = mine.find(r => r.diagnostic) || mine.find(r => r.state === "lost" || r.state === "failed");
        let why = `${c.running} of ${desired} running`;
        if (health === "converging") why = `${c.running} of ${desired} running, ${c.starting + c.pending + c.unscheduled} starting`;
        if (bad?.diagnostic) why = `${bad.id} on ${bad.node}: ${bad.diagnostic.summary}`;
        else if (bad) why = `${bad.id} ${bad.reason || bad.state}`;
        return { name: spec.name, spec, mod, desired, counts: c, replicas: mine, health, why, diagnostic: bad?.diagnostic || null };
      }).sort((a, b) => (a.name < b.name ? -1 : 1));
    });
  }

  nodeViews() {
    return this.memoized("nodes", () => {
      const reps = this.replicaViews();
      const out = [];
      for (const { value: n, lease } of this.nodes.values()) {
        const mine = reps.filter(r => r.node === n.name);
        const used = mine.reduce((a, r) => ({ cpu: a.cpu + (r.limits.cpu_millis || 0), mem: a.mem + (r.limits.memory_bytes || 0) }), { cpu: 0, mem: 0 });
        const info = this.leasePoll.byKey.get(`/nodes/${n.name}`);
        const fresh = info && Date.now() - this.leasePoll.at < 3 * POLL_MS;
        let state = "ready";
        if (fresh && info.remaining_ms < info.ttl_ms * 0.5) state = "expiring";
        out.push({ name: n.name, state, capacity: n.capacity, used, replicas: mine, address: n.address, agentVersion: n.agent_version, leaseId: lease, lease: info && { ttl_ms: info.ttl_ms, remaining_ms: info.remaining_ms, fresh }, labels: n.labels || [] });
      }
      const lost = new Map();
      for (const d of [...this.decisions.values()].sort((a, b) => (a.id < b.id ? -1 : 1))) {
        if (d.subject.kind !== "node") continue;
        if (d.action === "node_lost") lost.set(d.subject.name, d); else if (d.action === "node_joined") lost.delete(d.subject.name);
      }
      for (const [name, d] of lost) if (!this.nodes.has(name)) out.push({ name, state: "lost", capacity: null, used: null, replicas: [], lostAt: d.at_ms, lostReason: d.reason, lease: null, labels: [] });
      return out.sort((a, b) => (a.name < b.name ? -1 : 1));
    });
  }

  decisionList() { return this.memoized("decisions", () => [...this.decisions.values()].sort((a, b) => (a.id < b.id ? 1 : -1))); }

  attention() {
    return this.memoized("attention", () => {
      const items = [];
      for (const n of this.nodeViews()) {
        if (n.state === "lost") items.push({ key: `node/${n.name}`, kind: "node", name: n.name, state: "lost", detail: n.lostReason });
        else if (n.state === "expiring") items.push({ key: `node/${n.name}`, kind: "node", name: n.name, state: "expiring", detail: `lease has ${(n.lease.remaining_ms / 1000).toFixed(1)} s of ${n.lease.ttl_ms / 1000} s left; the agent may have stopped` });
      }
      for (const s of this.serviceViews()) if (s.health !== "healthy" && s.health !== "idle") items.push({ key: `service/${s.name}`, kind: "service", name: s.name, state: s.health, detail: s.why });
      const rank = { lost: 0, failing: 0, degraded: 1, expiring: 1, converging: 2 };
      return items.sort((a, b) => rank[a.state] - rank[b.state] || (a.key < b.key ? -1 : 1));
    });
  }

  totals() {
    return this.memoized("totals", () => {
      const svc = this.serviceViews(), rep = this.replicaViews(), nodes = this.nodeViews();
      return {
        services: svc.length, servicesHealthy: svc.filter(s => s.health === "healthy" || s.health === "idle").length,
        desired: svc.reduce((a, s) => a + s.desired, 0), running: rep.filter(r => r.state === "running").length,
        nodes: nodes.length, nodesReady: nodes.filter(n => n.state === "ready").length,
      };
    });
  }

  /** History for a subject: decisions held in the mirror (the newest few hundred). */
  historyFor(kind, name) {
    return this.decisionList().filter(d => d.subject.kind === kind && d.subject.name === name);
  }
}

export function numOf(id) { return Number(id.slice(id.lastIndexOf("-") + 1)) || 0; }
