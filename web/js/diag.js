// Diagnostics, rendered the way DIAGNOSTICS.md renders them. `cliDiagnostic` produces the exact
// text `zcube` prints; `diagnosticBlock` is the same content as markup. Both read one object, so
// the console cannot say anything the CLI would not.

import { h, command, copyButton } from "./ui.js";

const BLAME = {
  user: "your input",
  environment: "this host or environment",
  external: "an external service",
  internal: "a bug in zcube",
};
const BLAME_ICON = { user: "◇", environment: "▭", external: "↗", internal: "✱" };
const SEVERITY_GLYPH = { error: "✕", warning: "▲", note: "i", bug: "✱" };

const openDetail = new Set(); // which diagnostics have "Show detail" open, so a live rebuild keeps them open
const detailKey = d => d.code + "|" + d.summary + "|" + (d.causes || []).join("|");

export function product(code) { return code.startsWith("ZBX-") ? "zbx" : "zcube"; }
export function shortCode(code) { return code.slice(code.indexOf("-") + 1); }
export function docsUrl(code) {
  const base = code.startsWith("ZBX-") ? "https://zigbox.github.io/zigbox" : "https://zigbox.github.io/zigcube";
  return `${base}/errors/${shortCode(code)}.html`;
}
/** Where to report a bug: the tracker of the product whose registry the code belongs to. */
export function reportUrl(code) { return code.startsWith("ZBX-") ? "https://github.com/Zigbox/zigbox/issues/new" : "https://github.com/Zigbox/zigcube/issues/new"; }
export function explainCommand(code) { return `${product(code)} explain ${shortCode(code)}`; }

/** Fills the optional fields so renderers need no guards. */
export function normalize(d) {
  return {
    ...d,
    causes: d.causes || [], while: d.while || [], context: d.context || {}, fixes: d.fixes || [],
    omitted: { causes: 0, while: 0, context: 0, fixes: 0, ...(d.omitted || {}) },
  };
}

const pad = (label) => label.padEnd(6) + " ";

/** Text form, lines without trailing newline. `verbose` adds the cause chain and context. */
export function cliDiagnostic(input, { verbose = false } = {}) {
  const d = normalize(input);
  const kind = d.severity === "bug" ? "bug" : d.severity;
  const out = [`${kind}[${d.code}]: ${d.summary}`];
  if (d.severity === "bug") {
    out.push(`  this is a bug in ${product(d.code)}, not something you did`);
    if (d.saved) out.push(`  ${pad("saved")}diagnostic bundle: ${d.saved}`);
    out.push(`  ${pad("report")}${reportUrl(d.code)} (attach the bundle after reviewing it)`);
    if (verbose) for (const c of d.causes) out.push(`  ${pad("cause")}${c}`);
    return out;
  }
  if (verbose) for (const w of d.while) out.push(`  ${pad("while")}${w}`);
  const causes = verbose ? d.causes : d.causes.slice(-1);
  for (const c of causes) out.push(`  ${pad("cause")}${c}`);
  if (verbose && d.omitted.causes) out.push(`  ${pad("")}(${d.omitted.causes} more not shown)`);
  if (verbose) {
    for (const [k, v] of Object.entries(d.context)) out.push(`  ${pad(k)}${v}`);
    if (d.omitted.context) out.push(`  ${pad("")}(${d.omitted.context} more not shown)`);
  }
  d.fixes.forEach((f, i) => {
    const lead = i === 0 ? pad("fix") : pad("") + "or ";
    out.push(`  ${lead}${f.sentence}${f.command ? ":   " + f.command : ""}`);
  });
  out.push(`  ${pad("more")}${explainCommand(d.code)}${verbose ? "" : " · rerun with --verbose for the full cause chain"}`);
  out.push(`  ${pad("docs")}${docsUrl(d.code)}`);
  return out;
}

/** `zcube why` text for a chain returned by /v1/why. */
export function cliWhy(chain, { verbose = false } = {}) {
  const lines = [chain.state.text];
  for (const step of chain.steps) {
    if (step.diagnostic) {
      const [first, ...rest] = cliDiagnostic(step.diagnostic, { verbose });
      lines.push(`  ← ${first}`, ...rest.map(l => "    " + l));
    } else lines.push(`  ← ${step.text}`);
  }
  if (!chain.steps.length) lines.push("  (no decisions recorded for this subject)");
  return lines;
}

/** The block form. Default view mirrors default CLI output; "Show detail" is `--verbose`. */
export function diagnosticBlock(input, { compact = false, origin = null, requestId = null } = {}) {
  const d = normalize(input);
  const idBase = "d" + Math.random().toString(36).slice(2, 8);
  const detail = h("div", { class: "diag-detail", id: idBase + "-detail", hidden: true });
  const toggle = h("button", { type: "button", class: "linklike", "aria-expanded": "false", "aria-controls": idBase + "-detail" }, "Show detail");
  const hasDetail = d.severity === "bug" ? d.causes.length > 0 : d.while.length || d.causes.length > 1 || Object.keys(d.context).length || requestId;

  const row = (label, ...content) => h("div", { class: "drow" }, h("dt", {}, label), h("dd", {}, ...content));
  const rows = [];
  if (d.severity === "bug") {
    rows.push(h("p", { class: "bug-note" }, `This is a bug in ${product(d.code)}, not something you did.`));
    if (d.saved) rows.push(row("saved", h("code", {}, d.saved)));
    rows.push(row("report", h("a", { href: reportUrl(d.code), target: "_blank", rel: "noopener" }, "Open an issue"), " and attach the bundle after reviewing it"));
  } else {
    const inner = d.causes[d.causes.length - 1];
    if (inner) rows.push(row("cause", inner));
    for (const f of d.fixes) {
      rows.push(row(rows.some(r => r.dataset.fix) ? "or" : "fix", h("span", {}, f.sentence), f.command && command(f.command)));
      rows[rows.length - 1].dataset.fix = "1";
    }
  }
  rows.push(row("more", h("code", {}, explainCommand(d.code)), copyButton(explainCommand(d.code), "Copy"), " · ", h("a", { href: `#/codes/${d.code}` }, "Read the explanation here")));
  rows.push(row("docs", h("a", { href: docsUrl(d.code), target: "_blank", rel: "noopener" }, docsUrl(d.code).replace("https://", ""))));

  const drows = [];
  if (d.severity !== "bug") for (const w of d.while) drows.push(row("while", w));
  if (d.causes.length > 1 || d.severity === "bug") d.causes.forEach(c => drows.push(row("cause", c)));
  if (d.omitted.causes) drows.push(row("", `(${d.omitted.causes} more causes not shown)`));
  for (const [k, v] of Object.entries(d.context)) drows.push(row(k, h("code", {}, v)));
  if (d.omitted.context) drows.push(row("", `(${d.omitted.context} more context values not shown)`));
  if (requestId) drows.push(row("request", h("code", {}, requestId)));
  detail.append(h("dl", { class: "drows" }, ...drows));
  const setOpen = open => {
    detail.hidden = !open;
    toggle.setAttribute("aria-expanded", String(open));
    toggle.textContent = open ? "Hide detail" : "Show detail";
  };
  toggle.dataset.fid = "detail-" + detailKey(d);
  toggle.addEventListener("click", () => { const open = detail.hidden; setOpen(open); open ? openDetail.add(detailKey(d)) : openDetail.delete(detailKey(d)); });
  if (openDetail.has(detailKey(d))) setOpen(true);

  return h("article", { class: "diag" + (compact ? " compact" : ""), "data-severity": d.severity, "data-blame": d.blame, "aria-labelledby": idBase + "-h" },
    h("header", { class: "diag-h" },
      h("span", { class: "sev", "aria-hidden": "true" }, SEVERITY_GLYPH[d.severity] || "✕"),
      h("span", { class: "sev-word" }, d.severity),
      h("a", { class: "code", href: `#/codes/${d.code}` }, d.code),
      h("span", { class: "blame", title: "Whose problem this is (DIAGNOSTICS.md, blame)" }, h("span", { "aria-hidden": "true" }, BLAME_ICON[d.blame] + " "), "blame: " + BLAME[d.blame]),
      origin && h("span", { class: "origin" }, origin)),
    h("h3", { class: "diag-s", id: idBase + "-h" }, d.summary),
    h("dl", { class: "drows" }, ...rows),
    hasDetail && h("div", { class: "diag-more" }, toggle),
    detail);
}
