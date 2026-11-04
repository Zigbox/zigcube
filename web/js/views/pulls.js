// Pulls: what each image pull moved, by source (docs/keys.md, `/pulls/`; `zcube stats pull`).
// Values are shortened; a row's button (click, Enter or Space) expands the full digest, where each
// byte came from and a Copy button. Nothing is shown on hover only.
import { h, setText, rebuild, copyButton, emptyState, timeEl, plural } from "../ui.js";
import { diagnosticBlock } from "../diag.js";
import { pageHead } from "./parts.js";
import { bytesText, treeShort, tookText, peersTotal, peersText, sourcesText, moreText } from "../pulls_text.js";

const REFRESH_MS = 10000;
const filter = { node: "" };

export function pulls({ client, model }) {
  const body = h("tbody");
  const slot = h("div", { class: "empty-slot" });
  const count = h("p", { class: "sub" });
  const box = h("input", { id: "f-pulls", type: "search", class: "filter", placeholder: "Filter by node", "aria-label": "Filter pulls by node", autocomplete: "off", spellcheck: "false", "data-filter": "1" });
  box.value = filter.node;
  const open = new Set(); // `${node}/${tree}` rows that are expanded
  let data = null, error = null, lastRev = -1, lastAt = 0, inflight = false, stopped = false;

  const el = h("div", { class: "view" },
    pageHead("Pulls", "What each image pull moved: from the registry, from peers, or already held."),
    h("div", { class: "toolbar" }, box, count),
    h("section", { class: "card flush" }, h("div", { class: "table-wrap", tabindex: "0", role: "region", "aria-label": "Pulls table, scrolls sideways on narrow screens" }, h("table", { class: "grid wide" },
      h("thead", {}, h("tr", {}, h("th", {}, "Node"), h("th", {}, "Tree"), h("th", { class: "num" }, "Registry"), h("th", { class: "num" }, "Peers"), h("th", { class: "num hide-s" }, "Cached"), h("th", { class: "num hide-s" }, "Took"), h("th", {}, "Bad peers"), h("th", {}, "Finished"))),
      body)), slot));

  function rows(list) {
    return list.flatMap(p => {
      const key = `${p.node}/${p.tree}`;
      const expanded = open.has(key);
      const toggle = h("button", { type: "button", class: "linklike", "data-fid": key, "aria-expanded": String(expanded), "aria-label": `Details of the pull of ${p.tree} on ${p.node}` }, expanded ? "▾" : "▸");
      toggle.addEventListener("click", () => { if (open.has(key)) open.delete(key); else open.add(key); paint(); });
      const main = h("tr", { "data-pull": key },
        h("td", {}, toggle, " ", h("a", { href: `#/nodes/${p.node}` }, p.node)),
        h("td", {}, h("code", { class: "dim" }, treeShort(p.tree))),
        h("td", { class: "num" }, bytesText(p.registry_bytes)), h("td", { class: "num" }, bytesText(peersTotal(p))),
        h("td", { class: "num hide-s" }, bytesText(p.cached_bytes)), h("td", { class: "num hide-s" }, tookText(p.started_at_ms, p.finished_at_ms)),
        h("td", {}, p.bad_peers.length ? p.bad_peers.join(", ") : "–"), h("td", { class: "num" }, timeEl(p.finished_at_ms)));
      if (!expanded) return [main];
      const detail = h("tr", { class: "detail" }, h("td", { colspan: "8" },
        h("dl", { class: "kv" },
          h("dt", {}, "Tree"), h("dd", {}, h("code", {}, p.tree), " ", copyButton(p.tree, "Copy digest")),
          h("dt", {}, "Moved"), h("dd", {}, sourcesText(p)),
          h("dt", {}, "From peers"), h("dd", {}, peersText(p) || "–"),
          h("dt", {}, "Struck peers"), h("dd", {}, p.bad_peers.length ? `${p.bad_peers.join(", ")} sent a chunk that did not match its hash (ZC-W0601)` : "none"))));
      return [main, detail];
    });
  }

  function paint() {
    const q = box.value.trim().toLowerCase();
    filter.node = q;
    const all = data?.pulls ?? [];
    const list = all.filter(p => !q || p.node.toLowerCase().includes(q));
    const sig = JSON.stringify([list.map(p => [p.node, p.tree, p.finished_at_ms]), [...open]]);
    rebuild(body, sig, () => rows(list));
    setText(count, data ? `${list.length} of ${plural(all.length, "pull")}${data.skipped ? `, ${data.skipped} unreadable` : ""}${moreText(all.length, data) ? `; ${moreText(all.length, data)}` : ""}` : "Loading…", { flash: false });
    rebuild(slot, JSON.stringify([!!data, all.length, list.length, !!error]), () => {
      if (error) return error.diagnostics.map(d => diagnosticBlock(d, { origin: error.origin === "console" ? "raised by the console" : null, requestId: error.requestId }));
      if (!data) return [];
      if (!all.length) return [emptyState("No pulls recorded yet.", "A pull is recorded when a node finishes fetching an image tree.", "zcube stats pull")];
      return list.length ? [] : [h("p", { class: "muted pad" }, "No pull matches that filter.")];
    });
  }
  box.addEventListener("input", paint);

  async function load() {
    if (inflight || stopped) return;
    inflight = true; lastAt = Date.now();
    try { data = (await client.get("/v1/stats/pull?limit=500")).body; error = null; }
    catch (e) { if (!e.diagnostics) throw e; error = e; }
    finally { inflight = false; }
    lastRev = model.rev;
    if (!stopped) paint();
  }
  load();
  return {
    el,
    // Called on every model change: refetch when the store moved, at most every REFRESH_MS.
    update() { if (model.rev !== lastRev && Date.now() - lastAt > REFRESH_MS) load(); else paint(); },
    destroy() { stopped = true; },
  };
}
