// The code registry, readable in the browser: what `zcube explain <code>` prints.
import { h, setText, rebuild, copyButton, command, whyHref } from "../ui.js";
import { diagnosticBlock, docsUrl, explainCommand } from "../diag.js";

export function codes({ client }, params) {
  const code = params[0] ? decodeURIComponent(params[0]) : null;
  const list = h("ul", { class: "code-list" });
  const detail = h("section", { class: "card code-detail", "aria-live": "polite" });
  const filter = h("input", { id: "f-code", type: "search", class: "filter", placeholder: "Filter codes", "aria-label": "Filter codes", autocomplete: "off", "data-filter": "1" });
  let all = [], error = null;
  const el = h("div", { class: "view" },
    h("div", { class: "page-head" }, h("div", {}, h("h1", { id: "page-title", tabindex: "-1" }, "Diagnostic codes"), h("p", { class: "sub" }, "Every failure has a stable code. This is the same text as zcube explain."))),
    h("div", { class: "cols" }, h("div", { class: "col" }, h("div", { class: "toolbar" }, filter), h("section", { class: "card flush" }, list)), h("div", { class: "col" }, detail)));
  const render = () => {
    const q = filter.value.trim().toLowerCase();
    const rows = all.filter(c => !q || `${c.code} ${c.summary}`.toLowerCase().includes(q));
    rebuild(list, JSON.stringify([rows.map(r => r.code), code]), () => rows.map(c =>
      h("li", {}, h("a", { href: `#/codes/${c.code}`, "aria-current": c.code === code ? "true" : null, class: "code-row" }, h("code", {}, c.code), h("span", {}, c.summary), h("span", { class: "dim" }, c.blame)))));
  };
  filter.addEventListener("input", render);
  (async () => {
    try {
      all = (await client.get("/v1/codes")).body.codes;
      render();
      if (code) {
        const { body } = await client.get(`/v1/explain/${encodeURIComponent(code)}`);
        rebuild(detail, code, () => [h("h2", {}, body.code), h("p", { class: "summary" }, body.summary), h("p", { class: "dim" }, `${body.severity} · blame: ${body.blame}`),
          h("pre", { class: "explain" }, body.explanation), command(explainCommand(body.code)), h("p", {}, h("a", { href: docsUrl(body.code), target: "_blank", rel: "noopener" }, "Open the docs page"))]);
      } else rebuild(detail, "none", () => [h("p", { class: "muted" }, "Select a code to read what it means and what to do.")]);
    } catch (e) {
      if (!e.diagnostics) throw e;
      rebuild(detail, "err", () => e.diagnostics.map(d => diagnosticBlock(d, { origin: e.origin === "console" ? "raised by the console" : null, requestId: e.requestId })));
    }
  })();
  return { el, update() {} };
}
