// Service and node detail screens.
import { h, keyed, setText, setAttr, pill, setPill, whyHref, whyLink, digest, plural, timeEl, cpu, mem, rebuild, howTo, emptyState, command } from "../ui.js";
import { pageHead, makeReplicaBar, cpuMeter, memMeter, makeDecisionItem } from "./parts.js";
import { makeReplicaRow, replicaTable } from "./lists.js";

function dl(pairs) {
  return h("dl", { class: "kv" }, ...pairs.filter(Boolean).flatMap(([k, v]) => [h("dt", {}, k), h("dd", {}, v)]));
}
function notFound(kind, name) {
  return h("div", { class: "view" }, pageHead(`${kind} ${name}`, null), emptyState(`No ${kind} named “${name}”.`, "It may have been deleted, or the name is misspelled.", kind === "service" ? "zcube get service" : "zcube get nodes"),
    h("p", {}, h("a", { href: whyHref(kind, name) }, `Ask why ${kind} ${name} is not there`)));
}

export function serviceDetail({ model }, params) {
  const name = params[0];
  const status = pill("idle");
  const bar = makeReplicaBar();
  const head = h("div", { class: "page-head" }, h("div", {}, h("p", { class: "crumb" }, h("a", { href: "#/services" }, "Services")), h("h1", { id: "page-title", tabindex: "-1" }, name)),
    h("div", { class: "page-actions" }, status, bar.el, h("a", { class: "btn primary", href: whyHref("service", name) }, "Why")));
  const summary = h("p", { class: "lede" });
  const spec = h("div", { class: "spec" });
  const body = h("tbody");
  const hist = h("ol", { class: "decisions", "aria-label": `Decisions about ${name}` });
  const histEmpty = h("p", { class: "muted pad" }, "No decisions recorded for this service.");
  const missing = h("div");
  const main = h("div", { class: "view" },
    summary,
    howTo("The console is read-only. To change this service, edit its file and run", `zcube apply ${name}.zon`),
    h("section", { class: "card flush", "aria-labelledby": "h-reps" }, h("h2", { class: "pad-h", id: "h-reps" }, "Replicas"), replicaTable(body, { showService: false })),
    h("div", { class: "cols" },
      h("section", { class: "card", "aria-labelledby": "h-spec" }, h("h2", { id: "h-spec" }, "Spec"), spec),
      h("section", { class: "card", "aria-labelledby": "h-dh" }, h("div", { class: "card-h" }, h("h2", { id: "h-dh" }, "Decision history"), h("a", { href: whyHref("service", name) }, "Follow the chain")), hist, histEmpty)));
  const el = h("div", { class: "view" }, head, main, missing);

  return { el, update() {
    const s = model.serviceViews().find(x => x.name === name);
    main.hidden = head.hidden = !s;
    if (!s) { if (model.loaded) { missing.hidden = false; rebuild(missing, "nf", () => notFound("service", name)); } return; }
    missing.hidden = true;
    setPill(status, s.health); bar.update(s.counts, s.desired);
    setText(summary, s.why);
    const sp = s.spec;
    rebuild(spec, JSON.stringify([sp, s.mod]), () => dl([
      ["Image", h("code", {}, sp.image)], ["Replicas wanted", String(sp.replicas)], ["Generation", String(sp.generation)],
      ["Command", h("code", {}, sp.command.join(" "))],
      ["Environment", sp.env.length ? h("code", {}, sp.env.map(([k]) => `${k}=•••`).join("  ")) : "none"],
      ["Limits", `${cpu(sp.limits.cpu_millis)} CPU · ${mem(sp.limits.memory_bytes)} memory`],
      sp.applied_by && ["Last applied by", `${sp.applied_by} · request ${sp.request_id}`],
    ]));
    keyed(body, s.replicas, r => r.id, () => makeReplicaRow({ showService: false }));
    const ds = model.decisionList().filter(d => (d.subject.kind === "service" && d.subject.name === name) || (d.subject.kind === "replica" && d.subject.name.startsWith(name + "-"))).slice(0, 12);
    keyed(hist, ds, d => d.id, makeDecisionItem);
    histEmpty.hidden = ds.length > 0;
  } };
}

export function nodeDetail({ model }, params) {
  const name = params[0];
  const status = pill("ready");
  const head = h("div", { class: "page-head" }, h("div", {}, h("p", { class: "crumb" }, h("a", { href: "#/nodes" }, "Nodes")), h("h1", { id: "page-title", tabindex: "-1" }, name)),
    h("div", { class: "page-actions" }, status, h("a", { class: "btn primary", href: whyHref("node", name) }, "Why")));
  const summary = h("p", { class: "lede" });
  const facts = h("div", { class: "spec" });
  const c = cpuMeter(), m = memMeter();
  const body = h("tbody");
  const hist = h("ol", { class: "decisions" });
  const histEmpty = h("p", { class: "muted pad" }, "No decisions recorded for this node.");
  const missing = h("div");
  const main = h("div", { class: "view" }, summary,
    h("div", { class: "cols" },
      h("div", { class: "col" },
        h("section", { class: "card", "aria-labelledby": "h-cap" }, h("h2", { id: "h-cap" }, "Capacity"), h("div", { class: "kv-meters" }, h("span", { class: "dim" }, "CPU"), c.el, h("span", { class: "dim" }, "Memory"), m.el), facts),
        h("section", { class: "card", "aria-labelledby": "h-nd" }, h("div", { class: "card-h" }, h("h2", { id: "h-nd" }, "Decision history"), h("a", { href: whyHref("node", name) }, "Follow the chain")), hist, histEmpty)),
      h("div", { class: "col" }, h("section", { class: "card flush", "aria-labelledby": "h-nr" }, h("h2", { class: "pad-h", id: "h-nr" }, "Replicas on this node"), replicaTable(body)))));
  const el = h("div", { class: "view" }, head, main, missing);
  return { el, update() {
    const n = model.nodeViews().find(x => x.name === name);
    main.hidden = head.hidden = !n;
    if (!n) { if (model.loaded) { missing.hidden = false; rebuild(missing, "nf", () => notFound("node", name)); } return; }
    missing.hidden = true;
    setPill(status, n.state);
    if (n.state === "lost") { summary.replaceChildren("This node’s lease expired, so it is no longer registered. Last event ", timeEl(n.lostAt), "."); }
    else setText(summary, `${plural(n.replicas.length, "replica")} placed here${n.lease ? ` · lease ${(n.lease.remaining_ms / 1000).toFixed(1)} s of ${n.lease.ttl_ms / 1000} s` : ""}`);
    if (n.capacity) { c.update(n.used.cpu, n.capacity.cpu_millis); m.update(n.used.mem, n.capacity.memory_bytes); }
    rebuild(facts, JSON.stringify([n.address, n.agentVersion, n.leaseId, n.labels]), () => n.address ? dl([["Address", h("code", {}, n.address)], ["Agent", n.agentVersion], ["Lease", `#${n.leaseId}`], ["Labels", n.labels.length ? n.labels.join(", ") : "none"]]) : h("span"));
    keyed(body, n.replicas, r => r.id, () => makeReplicaRow());
    const ds = model.historyFor("node", name).slice(0, 12);
    keyed(hist, ds, d => d.id, makeDecisionItem);
    histEmpty.hidden = ds.length > 0;
  } };
}
