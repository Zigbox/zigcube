// Jobs (B1): the list at #/jobs and one job at #/jobs/<name>. A job runs once, on one node, to an
// end that is recorded (docs/keys.md, "Jobs"; GET /v1/jobs in docs/api.md).
//
// The console is read-only and shows only what the public routes return: a job's env as names
// (the route sends `env_names`, never values) and its input as a digest and size, never the
// input. Logs are not part of B1 (docs/decisions/2026-11-05-b1-owner-answers.md, answer 4): the
// job page says so and makes no log request. Every word for an ending cause comes from one table
// below, so the list, the page and the checks agree.
import { h, setText, rebuild, keyed, pill, setPill, timeEl, command, emptyState, plural, cpu, mem } from "../ui.js";
import { diagnosticBlock } from "../diag.js";
import { pageHead } from "./parts.js";
import { stepEl, completenessEl } from "./why.js";

const REFRESH_MS = 2000;
const STATES = ["pending", "placed", "running", "ended", "exited", "failed", "cancelled"]; // `ended`: every terminal state (api.md)
const filter = { state: "", text: "" };

/**
 * The closed set of ending causes of a failed job, in plain words. The meanings follow
 * docs/decisions/2026-11-05-b1-owner-answers.md (answer 6) and src/job_controller.zig: `fenced` is
 * an ending the agent reported (it stopped the run); `unreachable` is inferred (the node stopped
 * being heard); `not_started` is a node lost before any claim; `deadline` also covers a run that
 * did not start before its start-by time.
 */
export const CAUSE_TEXT = {
  oom: "ran out of memory",
  pid_limit: "hit its process limit",
  start_failed: "could not be started",
  deadline: "passed its deadline, or did not start in time",
  fenced: "was stopped: its agent reported that it stopped the run",
  unreachable: "its node stopped being heard",
  not_started: "its node was lost before the run was claimed",
  refused: "its node's trust policy refused it; nothing was started",
  unknown: "ended for a reason the agent could not tell",
};

/** The word for the Ended column: `exit 0`, `exit 3`, `signal 9`, `oom`, `cancelled`; "" while running. */
export function endShort(end) {
  if (!end) return "";
  if (end.kind === "exited") return end.signal != null ? `signal ${end.signal}` : `exit ${end.code}`;
  if (end.kind === "failed") return end.cause;
  return "cancelled";
}
export function endLong(end) {
  if (!end) return "";
  if (end.kind === "exited") return end.signal != null ? `exited: killed by signal ${end.signal}` : end.code === 0 ? "exited with code 0" : `exited with code ${end.code}`;
  if (end.kind === "failed") return `failed: ${CAUSE_TEXT[end.cause] || end.cause}`;
  return "cancelled";
}
/** The pill's state: a clean exit is calm, any other exit is an error. */
export function jobPill(state, end) {
  return state === "exited" && !(end && end.code === 0) ? "exited_bad" : state;
}

function errorBlocks(error) {
  return error.diagnostics.map(d => diagnosticBlock(d, { origin: error.origin === "console" ? "raised by the console" : null, requestId: error.requestId }));
}

// ---- The list ---------------------------------------------------------------------------------

function makeRow() {
  const name = h("a", { class: "name" });
  const state = pill("pending");
  const endEl = h("span");
  const node = h("span");
  const age = h("td", { class: "num" });
  const labels = h("td", { class: "hide-s" });
  const image = h("code", { class: "dim" });
  const el = h("tr", { "data-job": "" },
    h("td", {}, name), h("td", {}, state), h("td", {}, endEl), h("td", {}, node), h("td", { class: "hide-s" }, image), labels, age);
  let created = 0;
  return {
    el,
    update(j) {
      setText(name, j.name, { flash: false }); name.setAttribute("href", `#/jobs/${encodeURIComponent(j.name)}`);
      el.dataset.job = j.name;
      setPill(state, jobPill(j.state, j.end));
      setText(endEl, j.end ? endShort(j.end) : j.cancel_requested ? "cancel requested" : "");
      el.dataset.end = j.end ? endShort(j.end) : "";
      el.dataset.state = j.state;
      setText(node, j.node || "–");
      setText(image, j.image, { flash: false });
      setText(labels, j.labels.map(([k, v]) => `${k}=${v}`).join(" ") || "–", { flash: false });
      if (created !== j.created_at_ms) { created = j.created_at_ms; age.replaceChildren(timeEl(j.created_at_ms)); }
    },
  };
}

export function jobs({ client }) {
  const body = h("tbody");
  const slot = h("div", { class: "empty-slot" });
  const count = h("p", { class: "sub", role: "status" });
  const sel = h("select", { id: "f-job-state", "aria-label": "Filter jobs by state", "data-fid": "f-job-state" }, h("option", { value: "" }, "All states"), ...STATES.map(s => h("option", { value: s }, s === "ended" ? "ended (any end)" : s)));
  const box = h("input", { id: "f-jobs", type: "search", class: "filter", placeholder: "Filter by name", "aria-label": "Filter jobs by name", autocomplete: "off", spellcheck: "false", "data-filter": "1" });
  sel.value = filter.state; box.value = filter.text;
  let data = null, error = null, inflight = false, stopped = false, timer = 0, wantState = filter.state, depth = 0;

  const el = h("div", { class: "view" },
    pageHead("Jobs", "A job runs once, on one node, to an end that is recorded."),
    h("div", { class: "toolbar" }, sel, box, count),
    h("section", { class: "card flush" }, h("div", { class: "table-wrap", tabindex: "0", role: "region", "aria-label": "Jobs table, scrolls sideways on narrow screens" }, h("table", { class: "grid wide" },
      h("thead", {}, h("tr", {}, h("th", {}, "Name"), h("th", {}, "State"), h("th", {}, "Ended with"), h("th", {}, "Node"), h("th", { class: "hide-s" }, "Image"), h("th", { class: "hide-s" }, "Labels"), h("th", { class: "num" }, "Age"))),
      body)), slot));

  function paint() {
    const q = box.value.trim().toLowerCase();
    filter.text = q;
    const all = data?.jobs ?? [];
    const list = all.filter(j => !q || j.name.toLowerCase().includes(q));
    keyed(body, list, j => j.name, makeRow);
    const more = data?.continue ? "; more pages exist (the filter keeps a subset of each store page)" : "";
    setText(count, data ? `${list.length} of ${plural(all.length, "job")}${more}` : "Loading…", { flash: false });
    rebuild(slot, JSON.stringify([!!data, all.length, list.length, wantState, data?.continue, error && error.diagnostics]), () => {
      if (error) return errorBlocks(error);
      if (!data) return [];
      const next = data.continue ? h("p", { class: "pad" }, h("button", { class: "btn", type: "button", "data-next-page": "1", onclick: () => { depth++; load(); } }, "Show the next page")) : null;
      if (!list.length && data.continue) { // a filtered store page can be empty while more pages exist (api.md)
        return [h("p", { class: "muted pad" }, all.length ? "No job on this page matches that filter; more pages exist." : wantState ? `This page holds no ${wantState} job; more pages exist.` : "This page holds no job; more pages exist."), next];
      }
      if (!all.length) return [wantState
        ? h("p", { class: "muted pad" }, `No job is ${wantState}.`)
        : emptyState("No jobs yet.", "A job is submitted once and runs to an end. The command is the brief's (docs/briefs/b1.md); it arrives with the CLI.", "zcube job run NAME --image DIGEST --command ...")];
      return list.length ? [next] : [h("p", { class: "muted pad" }, "No job matches that filter.")];
    });
  }

  async function load() {
    if (inflight || stopped) return;
    inflight = true;
    const asked = filter.state;
    const base = `/v1/jobs?limit=500${asked ? `&state=${asked}` : ""}`;
    try {
      const r = (await client.get(base)).body;
      // Follow `continue` as far as the reader has asked, each page at the first page's revision.
      for (let i = 0; i < depth && r.continue; i++) {
        const n = (await client.get(`${base}&at=${r.revision}&continue=${encodeURIComponent(r.continue)}`)).body;
        r.jobs = r.jobs.concat(n.jobs); r.continue = n.continue;
      }
      if (asked === filter.state) data = r;
      error = null;
    } catch (e) { if (!e.diagnostics) throw e; error = e; }
    finally { inflight = false; }
    if (asked !== filter.state) { if (!stopped) return load(); return; } // the filter moved while this load ran
    wantState = filter.state;
    if (!stopped) paint();
  }
  const tick = () => { if (stopped) return; load(); timer = setTimeout(tick, REFRESH_MS); };
  sel.addEventListener("change", () => { filter.state = sel.value; depth = 0; data = null; paint(); load(); });
  box.addEventListener("input", paint);
  tick();
  return { el, update() { paint(); }, destroy() { stopped = true; clearTimeout(timer); } };
}

// ---- One job ----------------------------------------------------------------------------------

function dl(pairs) {
  return h("dl", { class: "kv" }, ...pairs.filter(Boolean).flatMap(([k, v]) => [h("dt", {}, k), h("dd", {}, v)]));
}
const when = ms => (ms ? timeEl(ms) : "–");
const span = ms => (ms >= 3600000 ? `${+(ms / 3600000).toFixed(1)} h` : ms >= 60000 ? `${+(ms / 60000).toFixed(1)} min` : `${+(ms / 1000).toFixed(1)} s`);

function specRows(job) {
  const lim = job.limits || {};
  return [
    ["Image", h("code", {}, job.image)],
    job.source && ["Source", h("code", {}, job.source)],
    ["Command", h("code", {}, job.command.join(" "))],
    // The route sends names only. The console says so rather than showing a placeholder that looks like a value.
    ["Environment", job.env_names.length ? h("span", {}, h("code", {}, job.env_names.join("  ")), h("span", { class: "dim" }, "  (values are not shown)")) : "none"],
    ["Input", job.input_digest ? h("span", {}, `${job.input_bytes} bytes in `, h("code", {}, job.input_env), " · ", h("code", { class: "dim", title: job.input_digest }, job.input_digest.slice(0, 15) + "…"), h("span", { class: "dim" }, "  (the input is not shown)")) : "none"],
    ["Limits", `${cpu(lim.cpu_millis)} CPU · ${mem(lim.memory_bytes)} memory${lim.pids != null ? ` · ${lim.pids} processes` : ""}`],
    ["Deadline", span(job.deadline_ms)],
    job.grace_ms ? ["Grace", span(job.grace_ms)] : null,
    job.labels.length ? ["Labels", job.labels.map(([k, v]) => `${k}=${v}`).join("  ")] : null,
    ["Submitted", h("span", {}, when(job.created_at_ms), job.applied_by ? ` by ${job.applied_by}` : "")],
    ["Start by", job.submit_by_ms ? h("time", { datetime: new Date(job.submit_by_ms).toISOString(), title: new Date(job.submit_by_ms).toLocaleString() }, new Date(job.submit_by_ms).toLocaleTimeString([], { hour12: false })) : "–"],
    job.cancel_requested ? ["Cancel requested", h("span", {}, when(job.cancel_requested.at_ms), job.cancel_requested.by ? ` by ${job.cancel_requested.by}` : "")] : null,
  ];
}

function statusRows(state, st, job) {
  const ended = !!st?.end;
  return [
    ["State", h("span", {}, pill(jobPill(state, st?.end)))],
    st?.node ? ["Node", h("a", { href: `#/nodes/${st.node}` }, st.node)] : ["Node", state === "pending" ? "not placed yet" : "–"],
    st?.started_at_ms ? ["Started", when(st.started_at_ms)] : null,
    ended ? ["Ended", h("span", {}, h("strong", {}, endLong(st.end)), " · ", when(st.ended_at_ms))] : job.cancel_requested ? ["Now", "cancel requested; the job controller is stopping the run"] : null,
    st?.stop_cause ? ["Stopped because", st.stop_cause] : null,
  ];
}

export function jobDetail({ client }, params) {
  const name = decodeURIComponent(params[0]);
  let job = null, chain = null, error = null, whyError = null, inflight = false, stopped = false, timer = 0, finishedOnce = false;

  const head = h("div", { class: "page-head" }, h("div", {}, h("p", { class: "crumb" }, h("a", { href: "#/jobs" }, "Jobs")), h("h1", { id: "page-title", tabindex: "-1" }, name)),
    h("div", { class: "page-actions" }, h("a", { class: "btn primary", href: `#/why/job/${encodeURIComponent(name)}` }, "Why")));
  const status = h("div", { class: "spec" });
  const spec = h("div", { class: "spec" });
  const diag = h("div", { class: "err-box" });
  const chainBox = h("div");
  const logs = h("section", { class: "card", "aria-labelledby": "h-logs" }, h("h2", { id: "h-logs" }, "Logs"),
    h("p", { class: "muted", "data-logs": "cut" }, "Logs are not part of this release: the job's output is not collected, so there is nothing to show here."));
  const missing = h("div");
  const main = h("div", { class: "view" },
    h("div", { class: "cols" },
      h("div", { class: "col" }, h("section", { class: "card", "aria-labelledby": "h-status" }, h("h2", { id: "h-status" }, "Status"), status, diag), chainBox),
      h("div", { class: "col" }, h("section", { class: "card", "aria-labelledby": "h-spec" }, h("h2", { id: "h-spec" }, "Spec"), spec), logs)));
  const el = h("div", { class: "view" }, head, missing, main);

  function paint() {
    main.hidden = head.querySelector(".page-actions").hidden = !job;
    if (!job) {
      rebuild(missing, JSON.stringify(error?.diagnostics || "loading"), () => error
        ? [...errorBlocks(error), error.status === 404 ? emptyState(`No job named “${name}”.`, "It may never have been submitted, or the name is misspelled.", "zcube job list") : null]
        : [h("p", { class: "muted pad" }, "Loading…")]);
      return;
    }
    rebuild(missing, JSON.stringify(error?.diagnostics || null), () => (error ? [h("p", { class: "muted pad" }, "The server could not be read just now; what follows may be out of date."), ...errorBlocks(error)] : []));
    const st = job.status;
    rebuild(status, JSON.stringify([job.state, st]), () => dl(statusRows(job.state, st, job.job)));
    rebuild(diag, JSON.stringify(st?.diagnostic || null), () => (st?.diagnostic ? [diagnosticBlock(st.diagnostic)] : []));
    rebuild(spec, JSON.stringify(job.job), () => dl(specRows(job.job)));
    rebuild(chainBox, JSON.stringify([chain, whyError && whyError.diagnostics]), () => [
      h("section", { class: "card", "aria-labelledby": "h-why" },
        h("div", { class: "card-h" }, h("h2", { id: "h-why" }, "Why"), h("a", { href: `#/why/job/${encodeURIComponent(name)}` }, "Open the full chain")),
        whyError ? errorBlocks(whyError) : !chain ? h("p", { class: "muted" }, "Loading…")
          : [h("p", { class: "why-text" }, chain.state.text), completenessEl(chain.completeness), h("ol", { class: "chain", "aria-label": "Causal chain, newest first; each step is the cause of the one above" }, ...chain.steps.map(stepEl))]),
      command(`zcube why job ${name}`)]);
  }

  async function load() {
    if (inflight || stopped) return;
    inflight = true;
    try {
      job = (await client.get(`/v1/jobs/${encodeURIComponent(name)}`)).body; error = null;
      try { chain = (await client.get(`/v1/why/job/${encodeURIComponent(name)}`)).body; whyError = null; } catch (e) { if (!e.diagnostics) throw e; whyError = e; }
    } catch (e) {
      if (!e.diagnostics) throw e;
      error = e; if (e.status === 404) job = null;
    } finally { inflight = false; }
    if (!stopped) paint();
  }
  const ended = () => ["exited", "failed", "cancelled"].includes(job?.state);
  const tick = () => {
    if (stopped) return;
    if (!ended() || !finishedOnce) { load().then(() => { finishedOnce = ended(); }); } // one more read after the end, then stop asking
    timer = setTimeout(tick, REFRESH_MS);
  };
  tick();
  return { el, update() { paint(); }, destroy() { stopped = true; clearTimeout(timer); } };
}
