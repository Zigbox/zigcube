// The proposed HTTP API (docs/api.md), served in the browser by the simulation. `request()` has
// the shape of `fetch`: it resolves to {status, headers, body} or rejects like a network failure.

import { StoreDown } from "./engine.js";
import { CODES, diagCompacted, diagBadRequest, diagFutureRevision, diagNotFound } from "./fixtures.js";

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

  async function request(method, url, { signal, body } = {}) {
    const requestId = engine.newRequestId();
    await sleep(LATENCY_MS[0] + Math.random() * (LATENCY_MS[1] - LATENCY_MS[0]));
    if (faults.apiDown) throw new TypeError("Failed to fetch");
    if (signal?.aborted) throw new DOMException("aborted", "AbortError");
    const u = new URL(url, "http://mock.local");
    const q = u.searchParams;
    const path = u.pathname;
    let m;
    try {
      if (path === "/v1/status") return reply(200, status(), requestId);
      if (!engine.storeUp) return fail(503, [engine.storeDiagnostic()], requestId);
      if (path === "/v1/list") return reply(200, list(q), requestId);
      if (path === "/v1/stats/pull") {
        const limit = Number(q.get("limit") ?? 50);
        if (!(limit >= 1 && limit <= 500)) return fail(400, [diagBadRequest("limit", "must be from 1 to 500")], requestId);
        const pulls = engine.pullList(q.get("node"), limit);
        return reply(200, { pulls, skipped: 0, matched: engine.pullList(q.get("node"), 500).length, truncated: false, revision: engine.rev }, requestId);
      }
      if (path === "/v1/jobs") {
        if (method === "POST") { const r = engine.jobs.submit(body ?? {}); return reply(r.status, r.body, requestId); }
        return reply(200, engine.jobs.list(q), requestId);
      }
      m = path.match(/^\/v1\/jobs\/([\w-]+)(\/cancel)?$/);
      // `/v1/jobs/watch` is the watch stream's route, not a job named "watch"; a job is read with GET only.
      if (m && m[1] !== "watch" && (m[2] ? method === "POST" : method === "GET")) {
        if (m[2]) { const r = engine.jobs.cancel(m[1], body?.applied_by); return reply(r.status, r.body, requestId); }
        return reply(200, engine.jobs.get(m[1]), requestId);
      }
      if (path === "/v1/leases") return reply(200, leases(), requestId);
      if (path === "/v1/watch") return await watch(q, signal, requestId);
      if (path === "/v1/codes") return reply(200, { codes: CODES.map(({ code, severity, blame, summary }) => ({ code, severity, blame, summary })) }, requestId);
      m = path.match(/^\/v1\/explain\/([\w-]+)$/);
      if (m) {
        const found = CODES.find(c => c.code === m[1]);
        return found ? reply(200, found, requestId) : fail(404, [diagNotFound(`code ${m[1]}`)], requestId);
      }
      m = path.match(/^\/v1\/services\/([\w.-]+)\/(history|rollout)(?:\/(pause|resume))?$/);
      if (m && (m[3] ? method === "POST" : method === "GET")) return services(m[1], m[2], m[3], body, requestId);
      m = path.match(/^\/v1\/why\/(service|replica|node|job)\/([\w.-]+)$/);
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

  // ---- Rollouts and history (docs/api.md, C3 slice 11) -------------------------------------

  const POLICY = { strategy: "rolling", max_surge: 1, max_unavailable: 0, min_ready_ms: 5000, ready_timeout_ms: 120000, progress_deadline_ms: 600000, grace_ms: 10000, on_failure: "rollback" };
  // The console reads with a read-only token: environment values come back as null, as the server redacts them.
  const redact = value => (value.env ? { ...value, env: value.env.map(([k]) => [k, null]) } : value);

  function services(name, what, verb, body, requestId) {
    const svc = engine.getKv(`/services/${name}`);
    if (!svc) return fail(404, [diagNotFound(`service ${name}`)], requestId);
    if (verb) {
      const r = engine.steerRollout(name, verb, body?.applied_by, requestId);
      return r.diagnostic ? fail(r.status, [r.diagnostic], requestId) : reply(r.status, r.body, requestId);
    }
    const base = { revision: engine.rev, service: name, generation: svc.value.generation };
    if (what === "history") {
      const kvs = engine.list(`/history/${name}/`).kvs.filter(kv => kv.value.generation <= svc.value.generation);
      const generations = kvs.sort((a, b) => b.value.generation - a.value.generation)
        .map(kv => ({ generation: kv.value.generation, mod_revision: kv.mod_revision, value: redact(kv.value) }));
      return reply(200, { ...base, generations }, requestId);
    }
    const kv = engine.rolloutOf(name);
    return reply(200, { ...base, replicas: svc.value.replicas, policy: { ...POLICY, ...(svc.value.rollout || {}) }, rollout: kv ? kv.value : null, mod_revision: kv ? kv.mod_revision : 0 }, requestId);
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
    let completeness = null;
    let entry = fromDecision ? index.find(e => e.id === fromDecision) : index[index.length - 1];
    if (fromDecision && !entry) throw Object.assign(new Error("none"), { status: 404, diagnostic: diagNotFound(`decision ${fromDecision}`) });
    let d = entry && engine.get(`/decisions/${entry.id}`);
    while (d) {
      steps.push({ type: "decision", text: d.reason, decision: d });
      const c = d.cause;
      if (c.kind === "decision") {
        d = engine.get(`/decisions/${c.id}`);
        if (!d) {
          // The server's rule (api.md, completeness): a chain that ends in a gone step is truncated.
          const reason = state.exists ? "retention" : "subject_deleted";
          steps.push({ type: "gone", reason, text: `decision ${c.id} has been removed by retention` });
          completeness = { verdict: "truncated", at: steps.filter(s => s.type === "decision").pop().decision.id, reason };
        }
        continue;
      }
      const gone = compactedStep(c, d);
      if (gone) {
        steps.push(gone);
        completeness = { verdict: "truncated", at: c.key, reason: "compacted" };
        break;
      }
      steps.push(terminal(c, d));
      break;
    }
    if (!completeness) completeness = { verdict: "complete" };
    if (kind === "node" && rebalanceNote(name)) steps.push(rebalanceNote(name));
    const out = { v: 1, revision: engine.rev, subject: { kind, name }, at_decision: fromDecision || null, state, steps };
    out.completeness = completeness;
    return out;
  }

  // The core's rule (docs/authority.md section 5): a cited key read below the compaction point is
  // `compacted` only if the key has changed since and the decision kept no copy of it.
  function compactedStep(c, d) {
    if (!c.key || c.revision == null || c.revision >= engine.compacted) return null;
    const kv = engine.getKv(c.key);
    if (kv && kv.mod_revision <= c.revision) return null;
    if (d.cause_evidence || d.cause_diagnostic) return null;
    return { type: "gone", reason: "compacted", key: c.key, revision: c.revision, text: `the record ${c.key} as it was at revision ${c.revision} is no longer kept` };
  }

  // The core's note: a ready node with fewer replicas than another is not rebalanced.
  function rebalanceNote(name) {
    if (!engine.get(`/nodes/${name}`)) return null;
    const all = engine.replicasIn("/replicas/");
    const mine = all.filter(r => r.node === name).length;
    const busiest = Math.max(0, ...[...new Set(all.map(r => r.node).filter(n => n && n !== name))].map(n => all.filter(r => r.node === n).length));
    if (mine >= busiest) return null;
    return { type: "note", text: "replicas that are already running on other nodes are not moved back: the scheduler places a replica when it is created or its node is lost, and does not rebalance" };
  }

  function terminal(c, d) {
    if (c.kind === "observed") {
      const live = engine.get(c.key);
      const diagnostic = d.cause_diagnostic || live?.diagnostic || null;
      if (c.key.startsWith("/job-observed/")) {
        // The words of src/why.zig `observed_step`: no exit, the report's diagnostic beside them.
        const text = live ? `${live.run} on ${live.node}: ${live.status}` : `${c.key} as it was at revision ${c.revision}`;
        return { type: "observed", key: c.key, revision: c.revision, text, diagnostic };
      }
      const o = c.key.startsWith("/observed/") ? live : null;
      if (c.key.startsWith("/nodes/")) return { type: "observed", key: c.key, revision: c.revision, text: `node ${c.key.split("/").pop()} registered under lease ${engine.getKv(c.key)?.lease ?? "?"} (revision ${c.revision})`, diagnostic: null };
      const text = o ? `${o.replica} on ${o.node}: ${o.status}${o.exit ? " (" + engine.exitText(o.exit) + ")" : ""}` : `${c.key} as it was at revision ${c.revision}`;
      return { type: "observed", key: c.key, revision: c.revision, text, diagnostic };
    }
    if (c.kind === "desired" && c.key.startsWith("/jobs/")) {
      const j = engine.get(c.key);
      const text = j ? `job ${j.name} was submitted by ${j.applied_by || "someone"}: deadline ${j.deadline_ms} ms${j.cancel_requested ? ", cancel requested" : ""}` : `submit of ${c.key} (revision ${c.revision})`;
      return { type: "desired", key: c.key, revision: c.revision, text, applied_by: j?.applied_by || null, request_id: null };
    }
    if (c.kind === "desired" && (c.key.startsWith("/job-runs/") || c.key.startsWith("/assigned/"))) {
      // The words of src/why.zig `desired_step`, which reads a run and an assignment as what they
      // are (docs/decisions/2026-11-06-why-job-desired-keys.md). The mock reads the record now.
      const v = engine.getKv(c.key)?.value;
      const text = c.key.startsWith("/assigned/") ? `${c.key} exists`
        : `run ${v?.id ?? c.key.split("/").pop()} of job ${v?.job ?? "?"} was created: deadline ${v?.deadline_ms ?? 0} ms${v?.stop ? ", stopped" : ""}`;
      return { type: "desired", key: c.key, revision: c.revision, text, applied_by: null, request_id: null };
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
      const reps = engine.replicasIn(`/replicas/${name}/`);
      const running = reps.filter(r => engine.observedOf(r)?.status === "running").length;
      const health = running === svc.replicas ? "healthy" : running === 0 && svc.replicas ? "failing" : "degraded";
      return { exists: true, health, desired: svc.replicas, running, text: `service ${name}: ${running}/${svc.replicas} running` };
    }
    if (kind === "replica") {
      const r = engine.replicasIn("/replicas/").find(x => x.id === name);
      if (!r) return { exists: false, health: "gone", text: `replica ${name}: gone` };
      const o = engine.observedOf(r);
      const st = !r.node ? "unscheduled" : !o ? `pending on ${r.node}` : o.status === "stopped" ? `${engine.exitText(o.exit)} on ${r.node}` : `${o.status} on ${r.node}`;
      return { exists: true, health: o?.status === "running" ? "healthy" : o?.status === "stopped" ? "failing" : "degraded", text: `replica ${name}: ${st}` };
    }
    if (kind === "job") {
      const j = engine.get(`/jobs/${name}`);
      if (!j) return { exists: false, health: "gone", text: `job ${name}: removed` };
      const st = engine.jobs.statusOf(name);
      const ended = engine.jobs.ended(name);
      const health = !ended ? "healthy" : st.state === "exited" && st.end.code === 0 ? "healthy" : "failing";
      const text = !st ? `job ${name}: pending, ${j.cancel_requested ? "cancel requested" : "not yet placed"}` : `job ${name}: ${st.state}`;
      return { exists: true, health, text };
    }
    const n = engine.get(`/nodes/${name}`);
    if (!n) return { exists: false, health: "gone", text: `node ${name}: not registered` };
    const count = engine.replicasIn("/replicas/").filter(r => r.node === name).length;
    return { exists: true, health: "healthy", text: `node ${name}: ready, lease ${engine.getKv(`/nodes/${name}`)?.lease} with ${count} ${count === 1 ? "replica" : "replicas"} assigned` };
  }

  return { request };
}
