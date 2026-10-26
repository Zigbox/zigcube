// Boot, routing, the shell (header, navigation, connection status) and keyboard shortcuts.
import { h, $, $$, setText, setAttr, clear, tickTimes, announce, clockTime, ago, serverNow } from "./ui.js";
import { createClient, fetchTransport } from "./api.js";
import { Model } from "./model.js";
import { diagnosticBlock } from "./diag.js";
import { overview } from "./views/overview.js";
import { services, replicas, nodes, decisions } from "./views/lists.js";
import { serviceDetail, nodeDetail } from "./views/details.js";
import { why } from "./views/why.js";
import { codes } from "./views/codes.js";

const ROUTES = [
  [/^$/, overview, "overview"],
  [/^services$/, services, "services"],
  [/^services\/([^/]+)$/, serviceDetail, "services"],
  [/^replicas$/, replicas, "replicas"],
  [/^nodes$/, nodes, "nodes"],
  [/^nodes\/([^/]+)$/, nodeDetail, "nodes"],
  [/^decisions$/, decisions, "decisions"],
  [/^why\/(service|replica|node)\/([^/]+)$/, why, "why"],
  [/^why$/, why, "why"],
  [/^codes(?:\/([^/]+))?$/, codes, "codes"],
];
const TITLES = { overview: "Overview", services: "Services", replicas: "Replicas", nodes: "Nodes", decisions: "Decisions", why: "Why", codes: "Codes" };

// ---- Theme -----------------------------------------------------------------------------------

const THEMES = ["system", "light", "dark"];
function loadTheme() { try { return localStorage.getItem("zc-theme") || "system"; } catch { return "system"; } }
function applyTheme(t) {
  const root = document.documentElement;
  if (t === "system") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", t);
  try { localStorage.setItem("zc-theme", t); } catch { /* storage may be blocked */ }
}

// ---- Boot ------------------------------------------------------------------------------------

async function boot() {
  const params = new URLSearchParams(location.search);
  const meta = (n) => document.querySelector(`meta[name="zcube-${n}"]`)?.content || "";
  const mockName = params.get("mock") ?? (meta("mock") || null);
  let transport = fetchTransport();
  let mock = null;
  if (mockName) {
    const { startMock } = await import("../mock/index.js");
    mock = startMock({ scenario: mockName, at: Number(params.get("at") ?? meta("mock-at") ?? 0) || 0, speed: Number(params.get("speed") || 1) || 1, backend: params.get("backend") || "postgres" });
    transport = mock.request;
    document.body.dataset.mock = mockName;
  }
  const client = createClient(transport);
  const model = new Model(client);
  let theme = loadTheme();
  applyTheme(theme);

  const ctx = { model, client, nav: hash => { location.hash = hash; }, mock };
  const main = $("#main");
  let current = null, currentKey = null, routed = false;

  function route() {
    const raw = location.hash.replace(/^#\/?/, "");
    const [path, qs] = raw.split("?");
    const query = new URLSearchParams(qs || "");
    for (const [re, factory, nav] of ROUTES) {
      const m = re.exec(path);
      if (!m) continue;
      const key = location.hash;
      if (key === currentKey) return;
      currentKey = key;
      current?.destroy?.();
      current = factory(ctx, m.slice(1), query);
      clear(main).append(current.el);
      current.update();
      for (const a of $$("nav.side a")) setAttr(a, "aria-current", a.dataset.nav === nav ? "page" : null);
      document.title = `${TITLES[nav]}${m[1] && nav !== "overview" ? ` · ${decodeURIComponent(m[m.length - 1] || m[1])}` : ""} · Zigcube`;
      window.scrollTo(0, 0);
      if (routed) $("#page-title")?.focus({ preventScroll: true }); // not on first load: the skip link stays the first Tab stop
      routed = true;
      announce(`${TITLES[nav]}`);
      return;
    }
    clear(main).append(h("div", { class: "view" }, h("h1", { id: "page-title", tabindex: "-1" }, "No such screen"), h("p", {}, h("a", { href: "#/" }, "Go to the overview"))));
    currentKey = location.hash;
  }
  addEventListener("hashchange", route);

  // ---- Connection pill and banner ----
  const pillEl = $("#conn");
  const connLog = $("#conn-log");
  const banner = $("#banner");
  const LABEL = { connecting: "Connecting", live: "Live", reconnecting: "Reconnecting", stale: "Stale", relisting: "Resyncing" };
  const GLYPH = { connecting: "◌", live: "●", reconnecting: "◐", stale: "▲", relisting: "◐" };
  let lastConn = "";
  function renderConn() {
    const s = model.connState;
    setAttr(pillEl, "data-conn", s);
    const detail = s === "live" ? `rev ${model.rev}` : s === "stale" && model.lastOkAt ? `as of ${clockTime(model.lastOkAt)}` : s === "relisting" ? "quietly relisting" : model.rev ? `rev ${model.rev}` : "";
    setText($(".c-glyph", pillEl), GLYPH[s], { flash: false });
    setText($(".c-label", pillEl), LABEL[s], { flash: false });
    setText($(".c-detail", pillEl), detail, { flash: false });
    if (s !== lastConn) { if (lastConn) announce(`Connection: ${LABEL[s]}`); lastConn = s; }
    const err = model.error;
    const sig = err ? JSON.stringify([err.diagnostics, err.requestId]) : "";
    const note = err ? (s === "stale" ? `The console is showing data from ${ago(model.lastOkAt)}. It keeps trying and will update itself.` : "Trying again. What you see is the last data received.") : "";
    if (banner._sig !== sig) {
      banner._sig = sig;
      banner.hidden = !err;
      banner._collapsed = matchMedia("(max-width: 760px)").matches; // a phone starts with the one-line form
      clear(banner);
      if (err) {
        const toggle = h("button", { type: "button", class: "linklike", "aria-expanded": String(!banner._collapsed) }, banner._collapsed ? "Show diagnostic" : "Hide diagnostic");
        const body = h("div", { class: "banner-body", hidden: banner._collapsed }, ...err.diagnostics.map(d => diagnosticBlock(d, { origin: err.origin === "console" ? "raised by the console" : null, requestId: err.requestId })));
        toggle.addEventListener("click", () => { banner._collapsed = !banner._collapsed; body.hidden = banner._collapsed; toggle.setAttribute("aria-expanded", String(!banner._collapsed)); toggle.textContent = banner._collapsed ? "Show diagnostic" : "Hide diagnostic"; });
        banner.append(h("p", { class: "banner-t" }, h("span", { class: "banner-note" }), " ", h("code", {}, err.diagnostics[0].code), " ", err.diagnostics[0].summary, " · ", toggle), body);
      }
    }
    const noteEl = banner.querySelector(".banner-note");
    if (noteEl) setText(noteEl, note, { flash: false });
    document.body.dataset.stale = s === "stale" || s === "reconnecting" ? "1" : "0";
  }
  $("#conn-btn").addEventListener("click", () => {
    const open = connLog.hidden;
    connLog.hidden = !open;
    $("#conn-btn").setAttribute("aria-expanded", String(open));
    if (open) renderLog();
  });
  function renderLog() {
    if (connLog.hidden) return;
    clear(connLog).append(h("h2", {}, "Connection"), h("p", { class: "dim" }, `Following the watch from revision ${model.rev}. ${model.store.backend ? "Store: " + model.store.backend + (model.store.ok ? "" : " (unreachable)") : ""}`),
      model.log.length ? h("ul", {}, ...model.log.slice(0, 12).map(l => h("li", { "data-level": l.level }, h("time", {}, clockTime(l.at)), " ", l.text))) : h("p", { class: "muted" }, "Nothing to report."));
  }

  // ---- Theme toggle ----
  const themeBtn = $("#theme");
  const paintTheme = () => { setText(themeBtn, `Theme: ${theme}`, { flash: false }); };
  themeBtn.addEventListener("click", () => { theme = THEMES[(THEMES.indexOf(theme) + 1) % 3]; applyTheme(theme); paintTheme(); announce(`Theme ${theme}`); });
  paintTheme();

  // ---- Nav toggle on phones is just a scrollable row; no script needed. ----

  // ---- Shortcuts: g then a letter; / focuses the filter; ? shows help ----
  let pendingG = 0;
  addEventListener("keydown", e => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.target;
    if (t.matches?.("input,textarea,select,[contenteditable]")) { if (e.key === "Escape") t.blur(); return; }
    if (e.key === "/") { const f = $("[data-filter]") || $("#why-name"); if (f) { e.preventDefault(); f.focus(); } return; }
    if (e.key === "?") { $("#help").hidden = !$("#help").hidden; return; }
    if (e.key === "Escape") { $("#help").hidden = true; connLog.hidden = true; return; }
    if (pendingG && Date.now() - pendingG < 1200) {
      const go = { o: "#/", s: "#/services", r: "#/replicas", n: "#/nodes", d: "#/decisions", w: "#/why", c: "#/codes" }[e.key];
      pendingG = 0;
      if (go) { location.hash = go; e.preventDefault(); }
      return;
    }
    if (e.key === "g") pendingG = Date.now();
  });

  // ---- Model updates ----
  model.subscribe(() => { current?.update(); renderConn(); renderLog(); });
  setInterval(() => { tickTimes(); renderConn(); }, 1000);
  model.start();
  route();
  renderConn();

  if (mock) {
    const { mountPanel } = await import("../mock/panel.js");
    mountPanel(mock);
  }
  window.zc = { model, mock }; // handy in the console during development
  addEventListener("error", e => console.error(e.error || e.message));
}

boot();
