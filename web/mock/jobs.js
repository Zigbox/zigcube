// The mock's jobs (B1): the routes of docs/api.md "Jobs", over keys of docs/keys.md "Jobs". Like the
// rest of the mock it is the shape of the real thing, not a copy of the controller: a job moves
// pending -> placed -> running -> one end, driven by a mock-only plan (the `plan` argument of
// `submit`), and writes the decisions `why job` walks. It never stores an env value's twin or the
// input: public replies carry `env_names`, `input_digest` and `input_bytes` only.
//
// Not modelled: retries, relay, placement (ZC-E0130 by name, as the server), the admission window
// beyond `jobs_max`, log output (cut from B1), node loss (a plan may end `unreachable` directly).

import { diagBadRequest } from "./fixtures.js";

export const JOBS_MAX = 512;
const NAME_MAX = 48;
const LONG_MS = 30000;
const NAME_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;
const FAILURES = ["oom", "pid_limit", "start_failed", "deadline", "fenced", "unreachable", "not_started", "unknown"];
const STOP_OF = { deadline: "deadline", fenced: "fence", unreachable: "unreachable", not_started: "not_started" };
const SPEC_FIELDS = ["image", "source", "command", "env", "limits", "deadline_ms", "labels", "grace_ms", "input_env"];
const KNOWN_FIELDS = new Set(["name", "submit_by_ms", "applied_by", "input", "retries", "relay", "placement", ...SPEC_FIELDS]);

const blame = (code, summary, cause, extra = {}) => ({
  code, severity: "error", blame: "user", summary, causes: [cause], while: [], context: extra.context || {},
  fixes: extra.fixes || [{ sentence: "correct the job and submit it again" }], omitted: { causes: 0, while: 0, context: 0, fixes: 0 },
});
const jobError = (status, diagnostic) => Object.assign(new Error(diagnostic.code), { status, diagnostic });
const field = (name, rule) => jobError(400, blame("ZC-E0130", "the job can't be accepted", `${name} ${rule}`, { context: { field: name } }));

function digestOf(text) { // not a hash: the mock only needs a stable, input-shaped stand-in
  let a = 0x811c9dc5, b = 0x1b873593;
  for (let i = 0; i < text.length; i++) { a = Math.imul(a ^ text.charCodeAt(i), 16777619); b = Math.imul(b + text.charCodeAt(i), 2246822519) ^ (b >>> 13); }
  return "sha256:" + [a, b, a ^ b, a + b].map(n => (n >>> 0).toString(16).padStart(8, "0")).join("").repeat(2);
}

export class Jobs {
  constructor(engine) {
    this.engine = engine;
    this.plans = new Map(); // name -> {node, place, start, run, outcome}
    this.inputBytes = new Map(); // name -> bytes, for display only; the input itself is not kept
    this.decisions = new Map(); // name -> the job's newest decision id
    this.timers = []; // long waits (over LONG_MS) that must not keep the engine "active" forever
  }

  // ---- Submit ------------------------------------------------------------------------------

  /** POST /v1/jobs. Returns {status, body}. `plan` is mock-only: how the run goes. */
  submit(body, plan = {}) {
    const e = this.engine;
    e.requireUp();
    for (const k of Object.keys(body)) if (!KNOWN_FIELDS.has(k)) throw jobError(400, diagBadRequest(k, "is not a field of a job"));
    for (const k of ["retries", "relay", "placement"]) if (body[k]) throw field(k, "is not built yet");
    const name = body.name;
    if (typeof name !== "string" || !name || name.length > NAME_MAX || !NAME_RE.test(name)) throw field("name", `must be 1 to ${NAME_MAX} lowercase letters, digits and dashes`);
    if (typeof body.image !== "string" || !body.image) throw field("image", "is required");
    if (!Array.isArray(body.command) || !body.command.length || body.command.length > 64) throw field("command", "must be 1 to 64 words");
    if (!Number.isInteger(body.deadline_ms) || body.deadline_ms < 1 || body.deadline_ms > 86400000) throw field("deadline_ms", "must be from 1 to 86400000");
    if (!Number.isInteger(body.submit_by_ms)) throw field("submit_by_ms", "is required");
    if ((body.labels || []).length > 6) throw field("labels", "holds at most 6 labels");
    const spec = {
      v: 1, name, image: body.image, source: body.source || "", command: body.command, env: body.env || [],
      limits: body.limits || {}, deadline_ms: body.deadline_ms, retries: 0, labels: body.labels || [], grace_ms: body.grace_ms ?? 0,
    };
    const text = body.input ?? "";
    if (body.input != null) {
      if (!body.input_env) throw field("input_env", "is required with input");
      spec.input_env = body.input_env;
      spec.input_digest = digestOf(text);
      spec.input_bytes = new TextEncoder().encode(text).length;
      if (spec.input_bytes > 65536) throw field("input", "is longer than 64 KiB");
    }
    const existing = e.get(`/jobs/${name}`);
    if (existing) {
      const same = SPEC_FIELDS.every(k => JSON.stringify(existing[k] ?? null) === JSON.stringify(spec[k] ?? null)) && existing.input_digest === spec.input_digest;
      if (!same) throw jobError(409, blame("ZC-E0131", "a job with this name exists with another spec", `job ${name} was submitted with a different spec`, { fixes: [{ sentence: "use another name, or look at the job that has this one", command: `zcube job get ${name}` }] }));
      return { status: 200, body: this.reply("exists", name) };
    }
    if (body.submit_by_ms <= e.now()) throw jobError(410, blame("ZC-E0134", "submit_by_ms has passed", `submit_by_ms ${body.submit_by_ms} is before the server's clock, ${e.now()}`));
    if (this.inFlight() >= JOBS_MAX) throw jobError(429, blame("ZC-E0132", "too many jobs", `${JOBS_MAX} jobs are in flight`));
    const record = { ...spec, submit_by_ms: body.submit_by_ms, created_at_ms: e.now(), applied_by: body.applied_by || "alex@laptop" };
    this.plans.set(name, { node: "node1", place: 600, start: 700, run: 3000, outcome: { kind: "exited", code: 0 }, ...plan });
    this.inputBytes.set(name, spec.input_bytes || 0);
    e.commit([{ put: [`/jobs/${name}`, record] }]);
    return { status: 201, body: this.reply("create", name) };
  }

  inFlight() { return this.names().filter(n => !this.ended(n)).length; }
  names() { return this.engine.list("/jobs/", { limit: 100000 }).kvs.map(kv => kv.value.name); }
  statusOf(name) { return this.engine.get(`/job-status/${name}`); }
  ended(name) { return ["exited", "failed", "cancelled"].includes(this.statusOf(name)?.state); }
  stateOf(name) { return this.statusOf(name)?.state || "pending"; }

  reply(action, name, extra = {}) {
    const st = this.statusOf(name);
    const out = { request_id: this.engine.newRequestId(), action, name, state: this.stateOf(name), revision: this.engine.rev, ...extra };
    if (st?.end) out.end = st.end;
    return out;
  }

  // ---- Cancel ------------------------------------------------------------------------------

  cancel(name, by = "alex@laptop") {
    const e = this.engine;
    e.requireUp();
    const job = e.get(`/jobs/${name}`);
    if (!job) throw this.missing(name);
    if (this.ended(name)) return { status: 200, body: this.reply("none", name) };
    if (job.cancel_requested) return { status: 202, body: this.reply("none", name) };
    e.commit([{ put: [`/jobs/${name}`, { ...job, cancel_requested: { at_ms: e.now(), by } }] }]);
    return { status: 202, body: this.reply("cancel", name) };
  }

  // ---- Reads -------------------------------------------------------------------------------

  missing(name) {
    return jobError(404, blame("ZC-E0133", "no such job", `job ${name} does not exist`, { fixes: [{ sentence: "list the jobs", command: "zcube job list" }] }));
  }

  /** The public form of a job: never an env value, never the input. */
  publicSpec(job) {
    const { env, ...rest } = job;
    return { ...rest, env_names: env.map(([k]) => k) };
  }

  get(name) {
    const job = this.engine.get(`/jobs/${name}`);
    if (!job) throw this.missing(name);
    return { revision: this.engine.rev, job: this.publicSpec(job), state: this.stateOf(name), status: this.statusOf(name) };
  }

  /** GET /v1/jobs: names in order; a filter keeps a subset of each store page (api.md). */
  list(q) {
    const limit = Number(q.get("limit") ?? 50);
    if (!(limit >= 1 && limit <= 500)) throw jobError(400, diagBadRequest("limit", "must be from 1 to 500"));
    const want = q.get("state");
    const label = q.get("label");
    const page = this.engine.list("/jobs/", { limit, after: q.get("continue") ? `/jobs/${q.get("continue")}` : null });
    const jobs = [];
    for (const kv of page.kvs) {
      const job = kv.value;
      const state = this.stateOf(job.name);
      if (want && want !== state && !(want === "ended" && this.ended(job.name))) continue;
      if (label) {
        const [k, v] = label.split("=");
        if (!job.labels.some(([a, b]) => a === k && (v === undefined || b === v))) continue;
      }
      const st = this.statusOf(job.name);
      const row = { name: job.name, image: job.image, state, labels: job.labels, created_at_ms: job.created_at_ms, deadline_ms: job.deadline_ms, cancel_requested: !!job.cancel_requested };
      if (st?.node) row.node = st.node;
      if (st?.end) row.end = st.end;
      jobs.push(row);
    }
    return { revision: this.engine.rev, jobs, continue: page.more ? page.last.slice("/jobs/".length) : null };
  }

  /** A wait: short ones run as engine tasks (the engine settles around them), long ones from `tick`. */
  later(ms, fn) {
    if (ms <= LONG_MS) { this.engine.after(ms, fn); return; }
    this.timers.push({ at: this.engine.t + ms, fn });
  }

  tick() {
    const due = this.timers.filter(t => t.at <= this.engine.t);
    if (!due.length) return;
    this.timers = this.timers.filter(t => t.at > this.engine.t);
    for (const t of due) t.fn();
  }

  // ---- The controller: called from Engine.reconcile ------------------------------------------

  reconcile() {
    for (const name of this.names()) {
      if (this.statusOf(name)) {
        if (!this.ended(name)) this.cancelStep(name);
        continue;
      }
      this.create(name);
    }
  }

  create(name) {
    const e = this.engine;
    const job = e.get(`/jobs/${name}`);
    const kv = e.getKv(`/jobs/${name}`);
    const d = e.decision({
      actor: "job-controller", action: "job_created", subject: { kind: "job", name },
      reason: "created the run for the job", cause: { kind: "desired", key: kv.key, revision: kv.mod_revision },
    });
    const start_by_ms = job.created_at_ms + job.deadline_ms;
    const run = { v: 1, id: `${name}-job`, job: name, image: job.image, source: job.source, command: job.command, env: job.env, limits: job.limits, deadline_ms: job.deadline_ms, grace_ms: job.grace_ms, labels: job.labels, start_by_ms, created_at_ms: e.now() };
    e.commit([...d.ops, { put: [`/job-runs/${name}`, run] }, { put: [`/job-status/${name}`, { v: 1, state: "pending", decision: d.id, reported_at_ms: e.now() }] }]);
    this.decisions.set(name, d.id);
    this.script(name, d.id);
  }

  /** Schedules the run's life from its plan; each step checks the job is still alive. */
  script(name, createdId) {
    const e = this.engine;
    const p = this.plans.get(name);
    const alive = () => !this.ended(name) && !!e.get(`/jobs/${name}`);
    const run = `${name}-job`;
    let last = createdId;
    const note = id => { last = id; this.decisions.set(name, id); };
    if (p.hold) { // ZC-W0308: no node fits; the job waits, then the start-by time passes
      this.later(p.place, () => {
        if (!alive()) return;
        const d = e.decision({
          actor: "scheduler", action: "hold_job", subject: { kind: "job", name },
          reason: "no node fits the run, or every node that fits is at jobs_per_node_max; it stays pending (ZC-W0308)", cause: { kind: "decision", id: last },
        });
        e.commit(d.ops); note(d.id);
      });
      this.later(p.hold, () => { if (alive()) this.stop(name, "deadline", last, null); });
      return;
    }
    this.later(p.place, () => {
      if (!alive()) return;
      const d = e.decision({ actor: "scheduler", action: "job_placed", subject: { kind: "job", name }, reason: "the run was assigned to a node", cause: { kind: "decision", id: last } });
      e.commit([...d.ops, { put: [`/assigned/${p.node}/${run}`, { v: 2, replica: run, service: "", job: name, requests: { cpu_millis: 250, memory_bytes: 134217728 }, reason: `${p.node} fits the run` }] },
        { put: [`/job-status/${name}`, { v: 1, state: "placed", node: p.node, epoch: e.rev + 1, decision: d.id, reported_at_ms: e.now() }] }]);
      note(d.id);
    });
    if (p.start == null) return; // stays placed
    if (p.outcome.never_started) { this.later(p.place + 1500, () => { if (alive()) this.stop(name, "not_started", last, null); }); return; }
    this.later(p.place + p.start, () => {
      if (!alive()) return;
      const obs = { v: 1, run, node: p.node, tenure: 7, assignment: e.rev, status: "running", started_at_ms: e.now(), reported_at_ms: e.now() };
      const okv = e.commit([{ put: [`/job-observed/${p.node}/${run}`, obs] }]);
      const d = e.decision({ actor: "job-controller", action: "job_running", subject: { kind: "job", name }, reason: "the run was claimed by its node", cause: { kind: "observed", key: `/job-observed/${p.node}/${run}`, revision: okv } });
      const st = this.statusOf(name);
      e.commit([...d.ops, { put: [`/job-status/${name}`, { ...st, state: "running", tenure: 7, started_at_ms: e.now(), decision: d.id, reported_at_ms: e.now() }] }]);
      note(d.id);
    });
    if (p.run == null) return; // runs until cancelled
    this.later(p.place + p.start + p.run, () => {
      if (!alive()) return;
      const o = p.outcome;
      if (o.kind === "exited") this.finish(name, { kind: "exited", ...(o.signal != null ? { signal: o.signal } : { code: o.code }) }, last, null, o);
      else if (STOP_OF[o.cause]) this.stop(name, STOP_OF[o.cause], last, o);
      else this.finish(name, { kind: "failed", cause: o.cause }, last, null, o);
    });
  }

  cancelStep(name) {
    const e = this.engine;
    const job = e.get(`/jobs/${name}`);
    if (!job?.cancel_requested) return;
    const st = this.statusOf(name);
    if (st.stop_cause) return;
    this.stop(name, "cancel", this.decisions?.get(name), null);
  }

  /** A stop decision, then the end it leads to (the ending follows the stop cause, not the exit alone). */
  stop(name, cause, after, outcome) {
    const e = this.engine;
    const st = this.statusOf(name);
    const kv = e.getKv(`/jobs/${name}`);
    const reason = ({
      cancel: "the job was cancelled, so its run is stopped",
      deadline: "the job's deadline passed before it ended, so its run is stopped",
      fence: "the run's node was fenced, so the run is stopped",
      not_started: "the run was assigned but the agent never started it before its start-by time",
      unreachable: "the node of the run was lost and did not come back within the grace",
    })[cause];
    const d = e.decision({
      actor: "job-controller", action: "stop_job", subject: { kind: "job", name }, reason,
      cause: cause === "cancel" ? { kind: "desired", key: kv.key, revision: kv.mod_revision } : { kind: "decision", id: after },
    });
    e.commit([...d.ops, { put: [`/job-status/${name}`, { ...st, stop_cause: cause, decision: d.id, reported_at_ms: e.now() }] }]);
    this.decisions.set(name, d.id);
    const end = cause === "cancel" ? { kind: "cancelled" } : { kind: "failed", cause: outcome?.cause ?? (cause === "fence" ? "fenced" : cause) };
    this.later(st.state === "pending" ? 0 : 400, () => { if (!this.ended(name)) this.finish(name, end, d.id, cause, outcome); });
  }

  exitOf(end) {
    if (end.kind === "exited") return { kind: "exited", ...(end.signal != null ? { signal: end.signal } : { code: end.code }) };
    if (end.kind === "failed") return { kind: ({ oom: "oom", pid_limit: "pid_limit", start_failed: "start_failed" })[end.cause] || (end.cause === "unknown" ? "lost" : "signaled"), ...(["deadline", "fenced"].includes(end.cause) ? { signal: 15 } : {}) };
    return { kind: "signaled", signal: 15 };
  }

  finish(name, end, after, stop, outcome) {
    const e = this.engine;
    const st = this.statusOf(name);
    const p = this.plans.get(name);
    const node = st.node || null;
    let cause = { kind: "decision", id: after };
    if (node && st.state !== "pending" && stop !== "not_started" && stop !== "unreachable") { // the agent's last report: the evidence the end rests on
      const rec = { v: 1, run: `${name}-job`, node, tenure: st.tenure || 7, assignment: st.epoch || e.rev, status: "stopped", exit: this.exitOf(end), reported_at_ms: e.now() };
      if (st.started_at_ms) rec.started_at_ms = st.started_at_ms;
      if (stop) rec.stop_cause = stop;
      const rev = e.commit([{ put: [`/job-observed/${node}/${name}-job`, rec] }]);
      cause = { kind: "observed", key: `/job-observed/${node}/${name}-job`, revision: rev };
    }
    const text = end.kind === "exited" ? (end.signal != null ? `exited on signal ${end.signal}` : `exited with code ${end.code}`) : end.kind === "failed" ? `failed: ${end.cause}` : "cancelled";
    const d = e.decision({
      actor: "job-controller", action: "end_job", subject: { kind: "job", name }, reason: `the run ended as its agent reported: ${text}`,
      cause, causeDiagnostic: end.kind === "failed" ? p?.diagnostic : undefined,
    });
    const status = { ...st, state: end.kind, end, ended_at_ms: e.now(), decision: d.id, reported_at_ms: e.now() };
    if (stop) status.stop_cause = stop;
    if (p?.diagnostic && end.kind === "failed") status.diagnostic = p.diagnostic;
    e.commit([...d.ops, { put: [`/job-status/${name}`, status] }]);
    this.decisions.set(name, d.id);
  }
}

export { FAILURES };
