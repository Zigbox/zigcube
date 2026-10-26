// The table screens: services, replicas, nodes, decisions. Filters live in module state so they
// survive a live update and a trip to another screen.
import { h, keyed, setText, setAttr, pill, setPill, whyHref, digest, plural, emptyState, timeEl, clockTime, cpu, mem, rebuild } from "../ui.js";
import { pageHead, makeReplicaBar, cpuMeter, memMeter, makeMeter, makeDecisionItem } from "./parts.js";

const filters = { service: "", replica: "", replicaState: "all", decision: "", actor: "all" };

function filterBox(id, label, key, placeholder, onChange) {
  const input = h("input", { id, type: "search", class: "filter", placeholder, "aria-label": label, autocomplete: "off", spellcheck: "false", value: filters[key], "data-filter": "1" });
  input.addEventListener("input", () => { filters[key] = input.value.trim().toLowerCase(); onChange(); });
  input.value = filters[key];
  return input;
}
const matches = (text, q) => !q || text.toLowerCase().includes(q);

// ---- Replica rows (used by the replicas screen and the service screen) -----------------------

export function makeReplicaRow({ showService = true } = {}) {
  const id = h("a", { class: "name" });
  const svc = h("a", {});
  const node = h("a", {});
  const image = h("code", { class: "dim" });
  const status = pill("pending");
  const reason = h("span", {});
  const reasonLink = h("a", { class: "diag-ref" });
  const gen = h("span", { class: "num" });
  const at = h("td", { class: "num" });
  const tr = h("tr", {}, h("td", {}, id), showService && h("td", {}, svc), h("td", {}, node), h("td", { class: "hide-s" }, image), h("td", {}, status), h("td", { class: "reason" }, reason, reasonLink), h("td", { class: "num hide-s" }, gen), at);
  let ts = -1;
  return { el: tr, update(r) {
    setText(id, r.id, { flash: false }); setAttr(id, "href", whyHref("replica", r.id)); setAttr(id, "aria-label", `Why replica ${r.id}`);
    setText(svc, r.service, { flash: false }); setAttr(svc, "href", `#/services/${r.service}`);
    setText(node, r.node || "–", { flash: false }); setAttr(node, "href", r.node ? `#/nodes/${r.node}` : null);
    setText(image, digest(r.image), { flash: false }); setAttr(image, "title", r.image);
    setPill(status, r.state);
    setText(reason, r.diagnostic ? "" : r.reason);
    setText(reasonLink, r.diagnostic ? `${r.diagnostic.code} ${r.diagnostic.summary}` : "", { flash: true });
    setAttr(reasonLink, "href", r.diagnostic ? whyHref("replica", r.id) : null);
    setText(gen, r.generation, { flash: false });
    if (ts !== r.reportedAt) { ts = r.reportedAt; at.replaceChildren(r.reportedAt ? timeEl(r.reportedAt) : "–"); }
  } };
}

export function replicaTable(body, { showService = true } = {}) {
  return h("div", { class: "table-wrap", tabindex: "0", role: "region", "aria-label": "Replicas table, scrolls sideways on narrow screens" }, h("table", { class: "grid wide" },
    h("thead", {}, h("tr", {}, h("th", {}, "Replica"), showService && h("th", {}, "Service"), h("th", {}, "Node"), h("th", { class: "hide-s" }, "Image digest"), h("th", {}, "Status"), h("th", {}, "Exit reason"), h("th", { class: "hide-s" }, "Gen"), h("th", {}, "Reported"))), body));
}

// ---- Services --------------------------------------------------------------------------------

export function services({ model }) {
  const body = h("tbody");
  const empty = h("div", { class: "empty-slot" });
  const count = h("p", { class: "sub" });
  const filter = filterBox("f-svc", "Filter services by name", "service", "Filter services", () => update());
  const el = h("div", { class: "view" },
    pageHead("Services", null),
    h("div", { class: "toolbar" }, filter, count),
    h("section", { class: "card flush" }, h("div", { class: "table-wrap", tabindex: "0", role: "region", "aria-label": "Services table" }, h("table", { class: "grid wide" },
      h("thead", {}, h("tr", {}, h("th", {}, "Service"), h("th", {}, "Health"), h("th", {}, "Running"), h("th", {}, "What is happening"), h("th", { class: "hide-s" }, "Image"), h("th", { class: "hide-s" }, "Gen"), h("th", {}, h("span", { class: "sr-only" }, "Explain")))),
      body)), empty));
  function row() {
    const name = h("a", { class: "name" }); const st = pill("idle"); const bar = makeReplicaBar();
    const why = h("td", { class: "reason" }); const image = h("code", { class: "dim" }); const gen = h("td", { class: "num hide-s" }); const w = h("a", { class: "why-link" }, "why");
    return { el: h("tr", {}, h("td", {}, name), h("td", {}, st), h("td", {}, bar.el), why, h("td", { class: "hide-s" }, image), gen, h("td", { class: "end" }, w)), update(s) {
      setText(name, s.name, { flash: false }); setAttr(name, "href", `#/services/${s.name}`); setPill(st, s.health); bar.update(s.counts, s.desired);
      setText(why, s.why); setText(image, digest(s.spec.image), { flash: false }); setAttr(image, "title", s.spec.image); setText(gen, s.spec.generation, { flash: false });
      setAttr(w, "href", whyHref("service", s.name)); setAttr(w, "aria-label", `Why service ${s.name}`);
    } };
  }
  function update() {
    const all = model.serviceViews();
    const list = all.filter(s => matches(s.name, filters.service));
    keyed(body, list, s => s.name, row);
    setText(count, model.loaded ? `${list.length} of ${plural(all.length, "service")}` : "Loading…", { flash: false });
    empty.replaceChildren(...(list.length || !model.loaded ? [] : [all.length ? h("p", { class: "muted pad" }, "No service matches that filter.") : emptyState("No services yet.", "Declare one in a ZON file and apply it from your terminal.", "zcube apply hello.zon")]));
  }
  return { el, update };
}

// ---- Replicas --------------------------------------------------------------------------------

export function replicas({ model }) {
  const body = h("tbody");
  const empty = h("div", { class: "empty-slot" });
  const count = h("p", { class: "sub" });
  const filter = filterBox("f-rep", "Filter replicas by name, service, node or image", "replica", "Filter by name, service, node, image", () => update());
  const state = h("select", { id: "f-rep-state", class: "filter", "aria-label": "Show replicas in state" },
    ...[["all", "All states"], ["running", "Running"], ["notrunning", "Not running"]].map(([v, t]) => h("option", { value: v }, t)));
  state.value = filters.replicaState;
  state.addEventListener("change", () => { filters.replicaState = state.value; update(); });
  const el = h("div", { class: "view" }, pageHead("Replicas", null), h("div", { class: "toolbar" }, filter, state, count), h("section", { class: "card flush" }, replicaTable(body), empty));
  function update() {
    const all = model.replicaViews();
    const list = all.filter(r => matches(`${r.id} ${r.service} ${r.node} ${r.image}`, filters.replica) && (filters.replicaState === "all" || (filters.replicaState === "running") === (r => r.state === "running")(r)));
    keyed(body, list, r => r.id, () => makeReplicaRow());
    setText(count, model.loaded ? `${list.length} of ${all.length}` : "Loading…", { flash: false });
    empty.replaceChildren(...(list.length || !model.loaded ? [] : [h("p", { class: "muted pad" }, all.length ? "No replica matches that filter." : "No replicas yet. They appear when a service is applied.")]));
  }
  return { el, update };
}

// ---- Nodes -----------------------------------------------------------------------------------

const secs = ms => `${(ms / 1000).toFixed(1)} s`;

export function nodes({ model }) {
  const body = h("tbody");
  const empty = h("div", { class: "empty-slot" });
  const el = h("div", { class: "view" },
    pageHead("Nodes", "Capacity is what each agent declares. Used is the sum of its replicas' limits."),
    h("section", { class: "card flush" }, h("div", { class: "table-wrap", tabindex: "0", role: "region", "aria-label": "Nodes table" }, h("table", { class: "grid wide" },
      h("thead", {}, h("tr", {}, h("th", {}, "Node"), h("th", {}, "State"), h("th", {}, "Lease"), h("th", {}, "CPU used / declared"), h("th", {}, "Memory used / declared"), h("th", {}, "Replicas"), h("th", { class: "hide-s" }, "Address"), h("th", {}, h("span", { class: "sr-only" }, "Explain")))),
      body)), empty));
  function row() {
    const name = h("a", { class: "name" }); const st = pill("ready");
    const lease = makeMeter(secs, { lease: true }); const leaseTxt = h("span", { class: "muted" });
    const c = cpuMeter(), m = memMeter(); const reps = h("td", { class: "num" }); const addr = h("code", { class: "dim" }); const w = h("a", { class: "why-link" }, "why");
    const leaseCell = h("td", { class: "lease" }, lease.el, leaseTxt);
    return { el: h("tr", {}, h("td", {}, name), h("td", {}, st), leaseCell, h("td", {}, c.el), h("td", {}, m.el), reps, h("td", { class: "hide-s" }, addr), h("td", { class: "end" }, w)), update(n) {
      setText(name, n.name, { flash: false }); setAttr(name, "href", `#/nodes/${n.name}`); setPill(st, n.state);
      const lost = n.state === "lost";
      lease.el.hidden = lost || !n.lease; leaseTxt.hidden = !(lost || !n.lease);
      if (n.lease) lease.update(n.lease.remaining_ms, n.lease.ttl_ms);
      setText(leaseTxt, lost ? `expired ${""}` : "waiting for first reading", { flash: false });
      if (lost) { leaseTxt.replaceChildren("expired "); leaseTxt.append(timeEl(n.lostAt)); }
      c.el.hidden = m.el.hidden = lost; if (!lost) { c.update(n.used.cpu, n.capacity.cpu_millis); m.update(n.used.mem, n.capacity.memory_bytes); }
      setText(reps, lost ? "–" : n.replicas.length, { flash: false }); setText(addr, n.address || "–", { flash: false });
      setAttr(w, "href", whyHref("node", n.name)); setAttr(w, "aria-label", `Why node ${n.name}`);
    } };
  }
  return { el, update() {
    const list = model.nodeViews();
    keyed(body, list, n => n.name, row);
    empty.replaceChildren(...(list.length || !model.loaded ? [] : [emptyState("No nodes registered.", "A node appears when its agent registers and holds a lease.", "zcube-agent --node node1")]));
  } };
}

// ---- Decisions -------------------------------------------------------------------------------

export function decisions({ model }) {
  const body = h("tbody");
  const count = h("p", { class: "sub" });
  const filter = filterBox("f-dec", "Filter decisions by text", "decision", "Filter by subject, action or reason", () => update());
  const actor = h("select", { id: "f-dec-actor", class: "filter", "aria-label": "Show decisions by actor" }, h("option", { value: "all" }, "All actors"));
  actor.addEventListener("change", () => { filters.actor = actor.value; update(); });
  const el = h("div", { class: "view" }, pageHead("Decisions", "Every controller action is recorded with its cause. Select a row to follow the chain."),
    h("div", { class: "toolbar" }, filter, actor, count),
    h("section", { class: "card flush" }, h("div", { class: "table-wrap", tabindex: "0", role: "region", "aria-label": "Decisions table" }, h("table", { class: "grid wide" },
      h("thead", {}, h("tr", {}, h("th", {}, "When"), h("th", {}, "Actor"), h("th", {}, "Action"), h("th", {}, "Subject"), h("th", {}, "Reason"), h("th", {}, "Caused by"))), body))));
  function row() {
    const when = h("td", { class: "num" }); const act = h("td", {}); const action = h("td", {}); const subj = h("a", { class: "name" }); const reason = h("td", { class: "reason" }); const cause = h("td", {});
    let ts = 0;
    return { el: h("tr", {}, when, act, action, h("td", {}, subj), reason, cause), update(d) {
      if (ts !== d.at_ms) { ts = d.at_ms; when.replaceChildren(timeEl(d.at_ms)); }
      setText(act, d.actor, { flash: false }); setText(action, d.action, { flash: false });
      setText(subj, `${d.subject.kind} ${d.subject.name}`, { flash: false }); setAttr(subj, "href", whyHref(d.subject.kind, d.subject.name, `?decision=${d.id}`));
      setText(reason, d.reason, { flash: false }); setText(cause, ({ decision: "another decision", observed: "an observation", desired: "an apply", resync: "a resync", lease_expired: "a lease expiring" })[d.cause.kind] || d.cause.kind, { flash: false });
    } };
  }
  return { el, update() {
    const all = model.decisionList();
    const actors = [...new Set(all.map(d => d.actor))].sort();
    if (actors.join() !== actor._actors) { actor._actors = actors.join(); actor.replaceChildren(h("option", { value: "all" }, "All actors"), ...actors.map(a => h("option", { value: a }, a))); actor.value = filters.actor; }
    list(all);
  } };
  function list(all) {
    const rows = all.filter(d => (filters.actor === "all" || d.actor === filters.actor) && matches(`${d.subject.kind} ${d.subject.name} ${d.action} ${d.reason}`, filters.decision)).slice(0, 200);
    keyed(body, rows, d => d.id, row);
    setText(count, model.loaded ? `${rows.length} of ${all.length} held` : "Loading…", { flash: false });
  }
  function update() { list(model.decisionList()); }
}
