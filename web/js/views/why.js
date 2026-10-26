// The Why screen: `zcube why <kind> <name>` as a causal chain. The server computes the chain
// (/v1/why) and the text of every step, so this screen and the CLI cannot disagree; the console
// adds structure (who, when, links) around that text and never rewrites it.
import { h, setText, rebuild, timeEl, command, copyButton, whyHref, pill, setPill, STATES, emptyState } from "../ui.js";
import { diagnosticBlock, cliWhy } from "../diag.js";
import { exitText } from "../model.js";

const KINDS = ["service", "replica", "node"];
let verbose = false;

function redact(spec) {
  const out = { ...spec };
  if (Array.isArray(out.env)) out.env = out.env.map(([k]) => [k, "[hidden]"]);
  return out;
}

function picker({ model, nav }) {
  const sections = h("div", { class: "cols" });
  const el = h("div", { class: "view" }, h("div", { class: "page-head" }, h("div", {}, h("h1", { id: "page-title", tabindex: "-1" }, "Why"), h("p", { class: "sub" }, "Pick a service, replica or node to see the chain of causes behind its current state."))), sections);
  const group = (title, items) => h("section", { class: "card" }, h("h2", {}, title), items.length ? h("ul", { class: "chips" }, ...items) : h("p", { class: "muted" }, "None yet."));
  return { el, update() {
    const sv = model.serviceViews(), nv = model.nodeViews(), rv = model.replicaViews().filter(r => r.state !== "running");
    rebuild(sections, JSON.stringify([sv.map(s => [s.name, s.health]), nv.map(n => [n.name, n.state]), rv.map(r => [r.id, r.state])]), () => [
      h("div", { class: "col" }, group("Services", sv.map(s => h("li", {}, h("a", { href: whyHref("service", s.name) }, s.name), " ", pill(s.health)))), group("Replicas that are not running", rv.map(r => h("li", {}, h("a", { href: whyHref("replica", r.id) }, r.id), " ", pill(r.state))))),
      h("div", { class: "col" }, group("Nodes", nv.map(n => h("li", {}, h("a", { href: whyHref("node", n.name) }, n.name), " ", pill(n.state))))),
    ]);
  } };
}

export function why(ctx, params, query) {
  if (!params[0]) return picker(ctx);
  const { model, client, nav } = ctx;
  const kind = params[0], name = decodeURIComponent(params[1] || "");
  const decision = query.get("decision");
  let chain = null, error = null, inflight = false, lastVersion = -1, lastFetch = 0, timer = 0, destroyed = false;

  const form = h("form", { class: "subject-form", role: "search", "aria-label": "Choose what to explain" });
  const kindSel = h("select", { id: "why-kind", "aria-label": "Kind", "data-fid": "why-kind" }, ...KINDS.map(k => h("option", { value: k }, k)));
  const nameIn = h("input", { id: "why-name", type: "text", "aria-label": "Name", list: "why-names", autocomplete: "off", spellcheck: "false", value: name, "data-fid": "why-name" });
  const names = h("datalist", { id: "why-names" });
  kindSel.value = KINDS.includes(kind) ? kind : "service";
  form.append(kindSel, nameIn, names, h("button", { type: "submit", class: "btn primary" }, "Explain"));
  form.addEventListener("submit", e => { e.preventDefault(); const n = nameIn.value.trim(); if (n) nav(`#/why/${kindSel.value}/${encodeURIComponent(n)}`); });
  const fillNames = () => {
    const k = kindSel.value;
    const list = k === "service" ? model.serviceViews().map(s => s.name) : k === "replica" ? model.replicaViews().map(r => r.id) : model.nodeViews().map(n => n.name);
    const sig = list.join();
    if (names._sig !== sig) { names._sig = sig; names.replaceChildren(...list.map(v => h("option", { value: v }))); }
  };
  kindSel.addEventListener("change", fillNames);

  const banner = h("div", { class: "banner-at", hidden: true });
  const headline = h("section", { class: "card why-head", "aria-live": "off" });
  const chainEl = h("ol", { class: "chain", "aria-label": "Causal chain, newest first; each step is the cause of the one above" });
  const sideCli = h("pre", { class: "cli", tabindex: "0", "aria-label": "Output of zcube why" });
  const cliBar = h("div", { class: "cli-bar" });
  const record = h("div", { class: "record" });
  const related = h("div", { class: "related" });
  const errorBox = h("div", { class: "err-box" });

  const verboseBox = h("input", { type: "checkbox", id: "cli-verbose" });
  verboseBox.checked = verbose;
  verboseBox.addEventListener("change", () => { verbose = verboseBox.checked; renderCli(); });
  const termWrap = h("section", { class: "term", "aria-labelledby": "h-cli" },
    h("div", { class: "bar" }, h("span", { id: "h-cli" }, "same as the CLI"), h("span", { class: "bar-r" }, h("label", { class: "chk" }, verboseBox, " --verbose"), h("span", { class: "copy-slot" }))),
    sideCli);
  const cmdText = `zcube why ${kind} ${name}`;

  const el = h("div", { class: "view" },
    h("div", { class: "page-head" }, h("div", {}, h("p", { class: "crumb" }, "Why"), h("h1", { id: "page-title", tabindex: "-1" }, `${kind} ${name}`)), form),
    h("div", { class: "cmd-line" }, h("span", { class: "dim" }, "In a terminal:"), command(cmdText)),
    banner,
    h("div", { class: "cols why-cols" },
      h("div", { class: "col" }, headline, chainEl, errorBox),
      h("div", { class: "col sticky" }, termWrap, related, record)));

  function renderCli() {
    if (!chain) return;
    const text = cliWhy(chain, { verbose }).join("\n");
    sideCli.textContent = text;
    const slot = termWrap.querySelector(".copy-slot");
    slot.replaceChildren(copyButton(text, "Copy CLI output"));
  }

  async function load() {
    if (inflight || destroyed) return;
    inflight = true; lastFetch = Date.now(); lastVersion = model.version;
    try {
      const { body } = await client.get(`/v1/why/${kind}/${encodeURIComponent(name)}${decision ? `?decision=${encodeURIComponent(decision)}` : ""}`);
      chain = body; error = null;
    } catch (e) {
      if (!e.diagnostics) throw e;
      error = e;
      if (e.status === 404) chain = null;
    }
    inflight = false;
    render();
  }

  function stepEl(step, i) {
    const li = h("li", { class: `step ${step.type}` });
    const mark = h("span", { class: "because", "aria-hidden": "true" }, "because");
    const body = h("div", { class: "step-body" });
    if (step.type === "decision") {
      const d = step.decision;
      body.append(
        h("div", { class: "step-h" }, h("span", { class: "chip" }, d.actor), h("span", { class: "step-act" }, d.action), h("span", { class: "grow" }), timeEl(d.at_ms)),
        h("p", { class: "step-t" }, step.text),
        h("p", { class: "step-m" }, "about ", h("a", { href: whyHref(d.subject.kind, d.subject.name) }, `${d.subject.kind} ${d.subject.name}`), " · decision ", h("code", { title: d.id }, d.id.slice(-9))));
    } else if (step.type === "observed") {
      body.append(
        h("div", { class: "step-h" }, h("span", { class: "chip obs" }, "observed"), h("span", { class: "step-act" }, step.text)),
        step.diagnostic ? diagnosticBlock(step.diagnostic) : h("p", { class: "step-t" }, step.text),
        h("p", { class: "step-m" }, h("code", {}, step.key), ` at revision ${step.revision}`));
    } else if (step.type === "desired") {
      body.append(
        h("div", { class: "step-h" }, h("span", { class: "chip des" }, "apply"), h("span", { class: "step-act" }, step.text)),
        h("p", { class: "step-m" }, step.applied_by ? ["by ", h("strong", {}, step.applied_by), step.request_id ? [" · request ", h("code", {}, step.request_id)] : ""] : "No author recorded for this apply."));
    } else if (step.type === "lease_expired") {
      body.append(h("div", { class: "step-h" }, h("span", { class: "chip obs" }, "lease"), h("span", { class: "step-act" }, step.text)), h("p", { class: "step-m" }, h("code", {}, step.key), ` deleted at revision ${step.revision}`));
    } else {
      body.append(h("div", { class: "step-h" }, h("span", { class: "chip" }, step.type === "resync" ? "resync" : "history"), h("span", { class: "step-act" }, step.text)));
    }
    li.append(mark, body);
    return li;
  }

  function renderRecord() {
    const parts = [];
    if (kind === "service") {
      const s = model.services.get(name);
      if (s) parts.push(h("details", {}, h("summary", {}, "Service record"), h("pre", { class: "json" }, JSON.stringify(redact(s.value), null, 2))));
      const reps = model.replicaViews().filter(r => r.service === name);
      if (reps.length) parts.push(h("div", { class: "rel" }, h("h3", {}, "Replicas"), h("ul", { class: "chips" }, ...reps.map(r => h("li", {}, h("a", { href: whyHref("replica", r.id) }, r.id), " ", pill(r.state))))));
    } else if (kind === "replica") {
      const r = model.replicaViews().find(x => x.id === name);
      if (r) {
        parts.push(h("details", {}, h("summary", {}, "Replica and observed records"), h("pre", { class: "json" }, JSON.stringify({ desired: redact(r.spec), observed: r.obs || null }, null, 2))));
        parts.push(h("div", { class: "rel" }, h("h3", {}, "Related"), h("ul", { class: "chips" }, h("li", {}, h("a", { href: whyHref("service", r.service) }, `service ${r.service}`)), r.node && h("li", {}, h("a", { href: whyHref("node", r.node) }, `node ${r.node}`)))));
      }
    } else {
      const n = model.nodeViews().find(x => x.name === name);
      if (n && n.replicas.length) parts.push(h("div", { class: "rel" }, h("h3", {}, "Replicas here"), h("ul", { class: "chips" }, ...n.replicas.map(r => h("li", {}, h("a", { href: whyHref("replica", r.id) }, r.id), " ", pill(r.state))))));
    }
    rebuild(record, JSON.stringify(parts.map(p => p.textContent)), () => parts);
  }

  function render() {
    fillNames();
    if (error) {
      rebuild(errorBox, JSON.stringify(error.diagnostics) + error.requestId, () => [
        h("h2", { class: "sr-only" }, "The console could not answer"),
        ...error.diagnostics.map(d => diagnosticBlock(d, { origin: error.origin === "console" ? "raised by the console" : null, requestId: error.requestId })),
        error.status === 404 ? h("p", { class: "muted" }, "Look for the name on ", h("a", { href: kind === "service" ? "#/services" : kind === "node" ? "#/nodes" : "#/replicas" }, `the ${kind} list`), ".") : null,
      ]);
    } else rebuild(errorBox, "none", () => []);
    if (!chain) { rebuild(headline, error ? "x" : "loading", () => (error ? [] : [h("p", { class: "muted" }, "Loading…")])); headline.hidden = !!error; chainEl.replaceChildren(); sideCli.textContent = ""; return; }
    headline.hidden = false;
    banner.hidden = !chain.at_decision;
    if (chain.at_decision) rebuild(banner, chain.at_decision, () => [`Showing the chain as of decision `, h("code", {}, chain.at_decision.slice(-9)), ". ", h("a", { href: whyHref(kind, name) }, "Show the latest")]);
    const st = chain.state;
    rebuild(headline, JSON.stringify([st, chain.steps.length]), () => [
      h("div", { class: "why-state" }, pill(st.health === "gone" ? "gone" : st.health), h("p", { class: "why-text" }, st.text)),
      chain.steps.length ? null : h("p", { class: "muted" }, "No decisions are recorded for this subject. Decisions are kept for a limited time (docs/keys.md, retention)."),
    ]);
    rebuild(chainEl, JSON.stringify(chain.steps), () => chain.steps.map(stepEl));
    renderCli();
    renderRecord();
  }

  function schedule() {
    if (destroyed || inflight) return;
    const wait = Math.max(0, 800 - (Date.now() - lastFetch));
    clearTimeout(timer);
    timer = setTimeout(load, wait);
  }

  load();
  return {
    el,
    update() { fillNames(); if (model.version !== lastVersion && model.loaded) schedule(); else if (chain || error) renderRecord(); },
    destroy() { destroyed = true; clearTimeout(timer); },
  };
}
