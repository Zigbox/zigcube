// The rollout and generations cards of the service detail screen (C3 slice 11): a read of
// `GET /v1/services/{name}/rollout` and `GET /v1/services/{name}/history` (docs/api.md,
// "Rollouts and history"). The console stays read-only: pausing and resuming are shown as the
// commands that do them, `zcube rollout pause|resume <service>`.
import { h, rebuild, pill, setText, timeEl, plural, emptyState, howTo } from "../ui.js";
import { diagnosticBlock } from "../diag.js";

const REFRESH_MS = 2000;
const ACTIVE = new Set(["progressing", "rolling_back"]);

function dl(pairs) {
  return h("dl", { class: "kv" }, ...pairs.filter(Boolean).flatMap(([k, v]) => [h("dt", {}, k), h("dd", {}, v)]));
}
function seconds(ms) { return ms % 1000 === 0 ? `${ms / 1000}s` : `${(ms / 1000).toFixed(1)}s`; }

function rolloutCard(name, data) {
  const r = data.rollout;
  const p = data.policy;
  const policy = `${p.strategy}, surge ${p.max_surge}, unavailable ${p.max_unavailable}, min ready ${seconds(p.min_ready_ms)}, deadline ${seconds(p.progress_deadline_ms)}, on failure ${p.on_failure}`;
  if (!r) return [h("p", { class: "muted" }, `No rollout: generation ${data.generation} is what runs.`), dl([["Policy", policy]])];
  const state = pill(r.phase);
  const rows = dl([
    ["Phase", state],
    ["Generations", `${r.from} → ${r.to}${r.reason === "rollback" ? " (rollback)" : ""}`],
    ["Progress", `${plural(r.ready_new ?? 0, "new replica")} ready, ${plural(r.retired_old ?? 0, "old replica")} retired, of ${data.replicas}`],
    ["Started", timeEl(r.started_at_ms)],
    ACTIVE.has(r.phase) && ["Deadline", timeEl(r.deadline_at_ms)],
    r.phase === "paused" && ["Paused", h("span", {}, `by ${r.paused_by ?? "failure"} `, timeEl(r.paused_at_ms ?? r.started_at_ms))],
    ["Policy", policy],
  ]);
  const steer = r.phase === "paused"
    ? howTo("To continue it, run", `zcube rollout resume ${name}`)
    : ACTIVE.has(r.phase) && howTo("To hold it where it is, run", `zcube rollout pause ${name}`);
  return [rows, steer];
}

function generationsTable(data) {
  const items = data.generations;
  if (!items.length) return emptyState("No generations stored.", "Each apply that changes the service stores one.", null);
  const body = h("tbody", {}, ...items.map(g => h("tr", { "data-generation": g.generation },
    h("td", {}, String(g.generation), g.generation === data.generation ? h("span", { class: "muted" }, " · now") : null),
    h("td", {}, h("code", {}, g.value.image)),
    h("td", {}, g.value.reason === "rollback" && g.value.restores != null ? `rollback of ${g.value.restores}` : (g.value.reason || "apply")),
    h("td", { class: "hide-s" }, g.value.applied_by || "–"),
    h("td", { class: "hide-s" }, g.value.request_id || "–"))));
  return h("div", { class: "table-wrap", tabindex: "0", role: "region", "aria-label": "Generations table, scrolls sideways on narrow screens" },
    h("table", { class: "grid" }, h("thead", {}, h("tr", {}, h("th", {}, "Gen"), h("th", {}, "Image"), h("th", {}, "Reason"), h("th", { class: "hide-s" }, "Applied by"), h("th", { class: "hide-s" }, "Request"))), body));
}

export function serviceRollout({ client, model }, name) {
  const rolloutSlot = h("div", { class: "rollout" });
  const historySlot = h("div");
  const count = h("span", { class: "muted" });
  const el = h("div", { class: "cols" },
    h("section", { class: "card", "aria-labelledby": "h-ro" }, h("h2", { id: "h-ro" }, "Rollout"), rolloutSlot),
    h("section", { class: "card", "aria-labelledby": "h-gen" }, h("div", { class: "card-h" }, h("h2", { id: "h-gen" }, "Generations"), count), historySlot));
  let rollout = null, history = null, error = null, inflight = false, stopped = false, lastRev = -1, lastAt = 0;
  const path = `/v1/services/${encodeURIComponent(name)}`;

  function paint() {
    rebuild(rolloutSlot, JSON.stringify([rollout, error && error.requestId]), () => {
      if (error) return error.diagnostics.map(d => diagnosticBlock(d, { requestId: error.requestId }));
      return rollout ? rolloutCard(name, rollout) : h("p", { class: "muted" }, "Loading…");
    });
    rebuild(historySlot, JSON.stringify(history), () => history ? generationsTable(history) : []);
    setText(count, history ? plural(history.generations.length, "generation") + " stored" : "", { flash: false });
  }

  async function load() {
    if (inflight || stopped) return;
    inflight = true; lastAt = Date.now();
    try {
      const [r, g] = await Promise.all([client.get(`${path}/rollout`), client.get(`${path}/history`)]);
      rollout = r.body; history = g.body; error = null;
    } catch (e) { if (!e.diagnostics) throw e; error = e; }
    finally { inflight = false; }
    lastRev = model.rev;
    if (!stopped) paint();
  }
  load();
  return {
    el,
    update() { if (model.rev !== lastRev && Date.now() - lastAt > REFRESH_MS) load(); else paint(); },
    destroy() { stopped = true; },
  };
}
