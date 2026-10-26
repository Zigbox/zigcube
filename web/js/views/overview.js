import { h, keyed, setText, setAttr, pill, setPill, whyLink, whyHref, digest, plural, emptyState, command } from "../ui.js";
import { pageHead, makeReplicaBar, cpuMeter, memMeter, makeDecisionItem } from "./parts.js";

export function overview({ model }) {
  const summary = h("p", { class: "lede", "aria-live": "off" });
  const attnList = h("ul", { class: "attn-list", "aria-label": "Things that need attention" });
  const attnEmpty = h("p", { class: "attn-empty" }, h("span", { "aria-hidden": "true" }, "● "), "Nothing needs attention.");
  const svcBody = h("tbody");
  const svcEmpty = h("div", { class: "empty-slot" });
  const nodeList = h("ul", { class: "node-list" });
  const nodeEmpty = h("div", { class: "empty-slot" });
  const feed = h("ol", { class: "decisions", "aria-label": "Latest decisions" });
  const feedEmpty = h("div", { class: "empty-slot" });

  const el = h("div", { class: "view" },
    pageHead("Overview", null),
    summary,
    h("div", { class: "cols" },
      h("div", { class: "col" },
        h("section", { class: "card attn", "aria-labelledby": "h-attn" }, h("h2", { id: "h-attn" }, "Needs attention"), h("div", { class: "attn-box" }, attnList, attnEmpty)),
        h("section", { class: "card", "aria-labelledby": "h-svc" },
          h("div", { class: "card-h" }, h("h2", { id: "h-svc" }, "Services"), h("a", { href: "#/services" }, "All services")),
          h("div", { class: "table-wrap" }, h("table", { class: "grid" },
            h("thead", {}, h("tr", {}, h("th", {}, "Service"), h("th", {}, "Health"), h("th", {}, "Running"), h("th", { class: "hide-s" }, "Image"), h("th", {}, h("span", { class: "sr-only" }, "Explain")))),
            svcBody)), svcEmpty)),
      h("div", { class: "col" },
        h("section", { class: "card", "aria-labelledby": "h-nodes" },
          h("div", { class: "card-h" }, h("h2", { id: "h-nodes" }, "Nodes"), h("a", { href: "#/nodes" }, "All nodes")), nodeList, nodeEmpty),
        h("section", { class: "card", "aria-labelledby": "h-dec" },
          h("div", { class: "card-h" }, h("h2", { id: "h-dec" }, "Latest decisions"), h("a", { href: "#/decisions" }, "All decisions")), feed, feedEmpty))));

  function serviceRow() {
    const name = h("a", { class: "name" });
    const status = pill("idle");
    const bar = makeReplicaBar();
    const image = h("code", { class: "dim" });
    const why = h("a", { class: "why-link" }, "why");
    const tr = h("tr", {}, h("td", {}, name), h("td", {}, status), h("td", {}, bar.el), h("td", { class: "hide-s" }, image), h("td", { class: "end" }, why));
    return { el: tr, update(s) {
      setText(name, s.name, { flash: false }); setAttr(name, "href", `#/services/${s.name}`);
      setPill(status, s.health); bar.update(s.counts, s.desired);
      setText(image, digest(s.spec.image), { flash: false }); setAttr(image, "title", s.spec.image);
      setAttr(why, "href", whyHref("service", s.name)); setAttr(why, "aria-label", `Why service ${s.name}`);
    } };
  }
  function attnRow() {
    const glyph = h("span", { class: "pg", "aria-hidden": "true" });
    const kind = h("span", { class: "a-kind" });
    const name = h("span", { class: "a-name" });
    const state = h("span", { class: "a-state" });
    const detail = h("span", { class: "a-detail" });
    const a = h("a", { class: "attn-item" }, h("span", { class: "a-top" }, pill("idle"), kind, name), detail, h("span", { class: "a-go", "aria-hidden": "true" }, "Why →"));
    return { el: h("li", {}, a), update(i) {
      setPill(a.querySelector(".pill"), i.state); setText(kind, i.kind, { flash: false }); setText(name, i.name, { flash: false });
      setText(detail, i.detail); setAttr(a, "href", whyHref(i.kind, i.name)); setAttr(a, "aria-label", `Why ${i.kind} ${i.name}: ${i.state}. ${i.detail}`);
    } };
  }
  function nodeRow() {
    const name = h("a", { class: "name" });
    const status = pill("ready");
    const c = cpuMeter(), m = memMeter();
    const count = h("span", { class: "dim" });
    return { el: h("li", { class: "node-row" }, h("span", { class: "n-top" }, name, status, count), c.el, m.el), update(n) {
      setText(name, n.name, { flash: false }); setAttr(name, "href", `#/nodes/${n.name}`); setPill(status, n.state);
      setText(count, n.state === "lost" ? "" : plural(n.replicas.length, "replica"));
      c.el.hidden = m.el.hidden = !n.capacity;
      if (n.capacity) { c.update(n.used.cpu, n.capacity.cpu_millis); m.update(n.used.mem, n.capacity.memory_bytes); }
    } };
  }

  return {
    el,
    update() {
      const t = model.totals();
      setText(summary, model.loaded
        ? `${t.servicesHealthy} of ${plural(t.services, "service")} healthy · ${t.running} of ${t.desired} replicas running · ${t.nodesReady} of ${plural(t.nodes, "node")} ready`
        : "Loading the cluster…", { flash: false });
      const items = model.attention();
      keyed(attnList, items, i => i.key, attnRow);
      attnEmpty.hidden = items.length > 0;
      const svcs = model.serviceViews();
      keyed(svcBody, svcs, s => s.name, serviceRow);
      svcEmpty.replaceChildren(...(svcs.length || !model.loaded ? [] : [emptyState("No services yet.", "Services are declared in ZON files and applied from your terminal.", "zcube apply hello.zon")]));
      const nodes = model.nodeViews();
      keyed(nodeList, nodes, n => n.name, nodeRow);
      nodeEmpty.replaceChildren(...(nodes.length || !model.loaded ? [] : [emptyState("No nodes registered.", "A node appears here when its agent registers.", "zcube-agent --node node1")]));
      const ds = model.decisionList().slice(0, 8);
      keyed(feed, ds, d => d.id, makeDecisionItem);
      feedEmpty.replaceChildren(...(ds.length || !model.loaded ? [] : [h("p", { class: "muted" }, "No decisions recorded yet.")]));
    },
  };
}
