// The proposed HTTP API (docs/api.md), served in the browser by the simulation. `request()` has
// the shape of `fetch`: it resolves to {status, headers, body} or rejects like a network failure.

import { StoreDown } from "./engine.js";
import { CODES, diagCompacted, diagFutureRevision, diagNotFound } from "./fixtures.js";

const WATCH_MAX_MS = 25000;
const LATENCY_MS = [15, 60];

export function createMockTransport(engine, faults) {
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  function reply(status, body, requestId) {
    return { status, headers: { "x-request-id": requestId, "content-type": "application/json" }, body };
  }
  function fail(status, diagnostics, requestId) {
    return reply(status, { request_id: requestId, diagnostics }, requestId);
  }

  async function request(method, url, { signal } = {}) {
    const requestId = engine.newRequestId();
    await sleep(LATENCY_MS[0] + Math.random() * (LATENCY_MS[1] - LATENCY_MS[0]));
    if (faults.apiDown) throw new TypeError("Failed to fetch");
    if (signal?.aborted) throw new DOMException("aborted", "AbortError");
    const u = new URL(url, "http://mock.local");
    const q = u.searchParams;
    const path = u.pathname;
    try {
      if (path === "/v1/status") return reply(200, status(), requestId);
      if (!engine.storeUp) return fail(503, [engine.storeDiagnostic()], requestId);
      if (path === "/v1/list") return reply(200, list(q), requestId);
      if (path === "/v1/leases") return reply(200, leases(), requestId);
      if (path === "/v1/watch") return await watch(q, signal, requestId);
      if (path === "/v1/codes") return reply(200, { codes: CODES.map(({ code, severity, blame, summary }) => ({ code, severity, blame, summary })) }, requestId);
      let m = path.match(/^\/v1\/explain\/([\w-]+)$/);
      if (m) {
        const found = CODES.find(c => c.code === m[1]);
        return found ? reply(200, found, requestId) : fail(404, [diagNotFound(`code ${m[1]}`)], requestId);
      }
      m = path.match(/^\/v1\/why\/(service|replica|node)\/([\w.-]+)$/);
      if (m) return reply(200, why(m[1], m[2], q.get("decision")), requestId);
      return fail(404, [diagNotFound(`route ${path}`)], requestId);
    } catch (e) {
      if (e instanceof StoreDown) return fail(503, [engine.storeDiagnostic()], requestId);
      if (e.diagnostic) return fail(e.status, [e.diagnostic], requestId);
      throw e;
    }
  }

  function status() {
    return {
      server: { version: "0.0.0-mock", started_at_ms: engine.base },
      store: engine.storeUp
        ? { backend: engine.backend, ok: true, revision: engine.rev, compacted_revision: engine.compacted }
        : { backend: engine.backend, ok: false, diagnostic: engine.storeDiagnostic() },
      time_ms: engine.now(),
    };
  }

  function list(q) {
    const at = q.get("at") ? Number(q.get("at")) : engine.rev;
    if (at < engine.compacted) throw Object.assign(new Error("compacted"), { status: 410, diagnostic: diagCompacted(at, engine.compacted) });
    if (at > engine.rev) throw Object.assign(new Error("future"), { status: 400, diagnostic: diagFutureRevision(at, engine.rev) });
    const r = engine.list(q.get("prefix") || "/", { at, reverse: q.get("reverse") === "true", limit: Math.min(500, Number(q.get("limit") || 500)), after: q.get("continue") });
    return { revision: at, kvs: r.kvs, continue: r.more ? r.last : null };
  }

  function leases() {
    return {
      time_ms: engine.now(),
      leases: [...engine.leases.values()].map(l => ({ id: l.id, ttl_ms: l.ttl, remaining_ms: Math.max(0, l.deadline - engine.t), keys: [...l.keys] })),
    };
  }

  async function watch(q, signal, requestId) {
    const prefixes = q.getAll("prefix");
    const from = Number(q.get("from"));
    if (from <= engine.compacted) return fail(410, [diagCompacted(from, engine.compacted)], requestId);
    if (from > engine.rev + 1) return fail(400, [diagFutureRevision(from, engine.rev)], requestId);
    const deadline = Date.now() + Math.min(WATCH_MAX_MS, Number(q.get("timeout") || WATCH_MAX_MS));
    for (;;) {
      if (faults.apiDown || engine.dead) throw new TypeError("Failed to fetch");
      if (!engine.storeUp) return fail(503, [engine.storeDiagnostic()], requestId);
      if (from <= engine.compacted) return fail(410, [diagCompacted(from, engine.compacted)], requestId);
      const r = engine.eventsFrom(prefixes.length ? prefixes : ["/"], from);
      if (r.events.length || Date.now() >= deadline) return reply(200, r, requestId);
      await new Promise((resolve, reject) => {
        const wake = () => { cleanup(); resolve(); };
        const timer = setTimeout(wake, Math.max(0, deadline - Date.now()));
        const onAbort = () => { cleanup(); reject(new DOMException("aborted", "AbortError")); };
        const cleanup = () => { clearTimeout(timer); engine.waiters.delete(wake); signal?.removeEventListener("abort", onAbort); };
        engine.waiters.add(wake);
        signal?.addEventListener("abort", onAbort);
      });
    }
  }

  // ---- Why: the causal chain, one text per step, shared with the CLI -----------------------

  function why(kind, name, fromDecision) {
    const state = subjectState(kind, name);
    const index = engine.list(`/decisions-by-subject/${kind}/${name}/`, { limit: 100000 }).kvs.map(kv => kv.value);
    const known = state.exists || index.length;
    if (!known) throw Object.assign(new Error("none"), { status: 404, diagnostic: diagNotFound(`${kind} ${name}`) });
    const steps = [];
    let entry = fromDecision ? index.find(e => e.id === fromDecision) : index[index.length - 1];
    if (fromDecision && !entry) throw Object.assign(new Error("none"), { status: 404, diagnostic: diagNotFound(`decision ${fromDecision}`) });
    let d = entry && engine.get(`/decisions/${entry.id}`);
    while (d) {
      steps.push({ type: "decision", text: d.reason, decision: d });
      const c = d.cause;
      if (c.kind === "decision") { d = engine.get(`/decisions/${c.id}`); if (!d) steps.push({ type: "gone", text: `decision ${c.id} has been removed by retention` }); continue; }
      steps.push(terminal(c, d));
      break;
    }
    return { v: 1, revision: engine.rev, subject: { kind, name }, at_decision: fromDecision || null, state, steps };
  }

  function terminal(c, d) {
    if (c.kind === "observed") {
      const live = engine.get(c.key);
      const diagnostic = d.cause_diagnostic || live?.diagnostic || null;
      const o = c.key.startsWith("/observed/") ? live : null;
      if (c.key.startsWith("/nodes/")) return { type: "observed", key: c.key, revision: c.revision, text: `node ${c.key.split("/").pop()} registered under lease ${engine.getKv(c.key)?.lease ?? "?"} (revision ${c.revision})`, diagnostic: null };
      const text = o ? `${o.replica} on ${o.node}: ${o.status}${o.exit ? " (" + engine.exitText(o.exit) + ")" : ""}` : `${c.key} as it was at revision ${c.revision}`;
      return { type: "observed", key: c.key, revision: c.revision, text, diagnostic };
    }
    if (c.kind === "desired") {
      const kv = engine.getKv(c.key);
      const v = kv?.value;
      const text = v ? `apply of ${v.name} (generation ${v.generation}, revision ${c.revision})` : `apply of ${c.key} (revision ${c.revision})`;
      return { type: "desired", key: c.key, revision: c.revision, text, applied_by: v?.applied_by || null, request_id: v?.request_id || null };
    }
    if (c.kind === "lease_expired") {
      return { type: "lease_expired", key: c.key, lease: c.lease, revision: c.revision, text: `lease ${c.lease} on ${c.key.split("/").pop()} expired after ${c.ttl_ms / 1000} s without a keepalive` };
    }
    return { type: "resync", text: "periodic resync found drift between desired and observed state" };
  }

  function subjectState(kind, name) {
    if (kind === "service") {
      const svc = engine.get(`/services/${name}`);
      if (!svc) return { exists: false, health: "gone", text: `service ${name}: deleted` };
      const reps = engine.values(`/replicas/${name}/`);
      const running = reps.filter(r => engine.observedOf(r)?.status === "running").length;
      const health = running === svc.replicas ? "healthy" : running === 0 && svc.replicas ? "failing" : "degraded";
      return { exists: true, health, desired: svc.replicas, running, text: `service ${name}: ${running}/${svc.replicas} running` };
    }
    if (kind === "replica") {
      const r = engine.values("/replicas/").find(x => x.id === name);
      if (!r) return { exists: false, health: "gone", text: `replica ${name}: gone` };
      const o = engine.observedOf(r);
      const st = !r.node ? "unscheduled" : !o ? `pending on ${r.node}` : o.status === "stopped" ? `${engine.exitText(o.exit)} on ${r.node}` : `${o.status} on ${r.node}`;
      return { exists: true, health: o?.status === "running" ? "healthy" : o?.status === "stopped" ? "failing" : "degraded", text: `replica ${name}: ${st}` };
    }
    const n = engine.get(`/nodes/${name}`);
    if (!n) return { exists: false, health: "gone", text: `node ${name}: not registered` };
    const count = engine.values("/replicas/").filter(r => r.node === name).length;
    return { exists: true, health: "healthy", text: `node ${name}: ready, ${count} ${count === 1 ? "replica" : "replicas"}` };
  }

  return { request };
}
