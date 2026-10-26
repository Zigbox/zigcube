// Small DOM helpers. The console has no framework, so the rules that keep live updates calm live
// here: `keyed` reconciles rows in place (no focus loss, no reorder unless the order changed),
// `setText` writes only on change, and `announce` batches screen-reader messages.

export function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "text") el.textContent = v;
    else if (k === "hidden") el.hidden = true;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  append(el, kids);
  return el;
}

export function append(el, kids) {
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
export function clear(el) { el.replaceChildren(); return el; }

/** Writes text only if it changed; a changed cell gets a brief highlight (not under reduced motion). */
export function setText(el, text, { flash = true } = {}) {
  text = String(text);
  if (el.textContent === text) return false;
  const had = el.textContent !== "";
  el.textContent = text;
  if (flash && had) pulse(el);
  return true;
}
export function pulse(el) {
  el.classList.remove("chg");
  void el.offsetWidth;
  el.classList.add("chg");
}
export function setAttr(el, name, value) {
  if (value == null || value === false) { if (el.hasAttribute(name)) el.removeAttribute(name); return; }
  value = value === true ? "" : String(value);
  if (el.getAttribute(name) !== value) el.setAttribute(name, value);
}

/** Keeps `container`'s children in step with `items`: rows are made once and updated in place. */
export function keyed(container, items, keyOf, make) {
  const rows = container._rows || (container._rows = new Map());
  const seen = new Set();
  let prev = null;
  for (const item of items) {
    const key = keyOf(item);
    seen.add(key);
    let row = rows.get(key);
    if (!row) { row = make(item); rows.set(key, row); }
    row.update(item);
    const want = prev ? prev.nextElementSibling : container.firstElementChild;
    if (row.el !== want) container.insertBefore(row.el, want);
    prev = row.el;
  }
  for (const [key, row] of rows) if (!seen.has(key)) { row.el.remove(); rows.delete(key); }
  return rows.size;
}

/**
 * Rebuilds `container` when `signature` changes, keeping keyboard focus on the element with the
 * same data-fid and the scroll position, so an update never moves the user's place.
 */
export function rebuild(container, signature, build) {
  if (container._sig === signature) return false;
  container._sig = signature;
  const active = document.activeElement;
  const fid = active && container.contains(active) ? active.dataset.fid : null;
  const wasText = active && container.contains(active) && active.matches("input,textarea") ? [active.selectionStart, active.selectionEnd] : null;
  container.replaceChildren(...[build()].flat(Infinity).filter(k => k != null && k !== false));
  if (fid) {
    const again = container.querySelector(`[data-fid="${CSS.escape(fid)}"]`);
    if (again) { again.focus({ preventScroll: true }); if (wasText) again.setSelectionRange?.(...wasText); }
  }
  return true;
}

// ---- Formatting ----------------------------------------------------------------------------

let clockOffset = 0;
export function setClockOffset(ms) { clockOffset = ms; }
export const serverNow = () => Date.now() + clockOffset;

export function ago(ts) {
  const s = Math.max(0, Math.round((serverNow() - ts) / 1000));
  if (s < 2) return "just now";
  if (s < 90) return `${s} s ago`;
  if (s < 5400) return `${Math.round(s / 60)} min ago`;
  if (s < 129600) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
}
export function clockTime(ts) {
  const d = new Date(ts);
  return d.toLocaleTimeString([], { hour12: false });
}
export function timeEl(ts) {
  const t = h("time", { datetime: new Date(ts).toISOString(), "data-ts": ts, title: new Date(ts).toLocaleString() });
  t.textContent = ago(ts);
  return t;
}
export function tickTimes(root = document) {
  for (const t of root.querySelectorAll("time[data-ts]")) {
    const text = ago(Number(t.dataset.ts));
    if (t.textContent !== text) t.textContent = text;
  }
}
export function cpu(m) { return m == null ? "–" : m >= 1000 ? `${+(m / 1000).toFixed(2)} CPU` : `${m} m`; }
export function mem(b) {
  if (b == null) return "–";
  const mib = b / 1048576;
  return mib >= 1024 ? `${+(mib / 1024).toFixed(1)} GiB` : `${Math.round(mib)} MiB`;
}
export function digest(d) { return d && d.length > 14 ? `${d.slice(0, 7)}…${d.slice(-2)}` : d || "–"; }
export function plural(n, one, many = one + "s") { return `${n} ${n === 1 ? one : many}`; }

// ---- Components ----------------------------------------------------------------------------

/** Status vocabulary: every state has a glyph and a word, never colour alone. */
export const STATES = {
  running: { glyph: "●", label: "running", tone: "ok" },
  healthy: { glyph: "●", label: "healthy", tone: "ok" },
  ready: { glyph: "●", label: "ready", tone: "ok" },
  starting: { glyph: "◐", label: "starting", tone: "info" },
  pending: { glyph: "◐", label: "pending", tone: "info" },
  converging: { glyph: "◐", label: "converging", tone: "info" },
  unscheduled: { glyph: "◌", label: "unscheduled", tone: "warn" },
  degraded: { glyph: "▲", label: "degraded", tone: "warn" },
  expiring: { glyph: "▲", label: "lease expiring", tone: "warn" },
  stopped: { glyph: "■", label: "stopped", tone: "muted" },
  failed: { glyph: "✕", label: "failed", tone: "err" },
  failing: { glyph: "✕", label: "failing", tone: "err" },
  lost: { glyph: "✕", label: "lost", tone: "err" },
  gone: { glyph: "○", label: "gone", tone: "muted" },
  idle: { glyph: "○", label: "idle", tone: "muted" },
};
export function pill(state) {
  const el = h("span", { class: "pill" }, h("span", { "aria-hidden": "true", class: "pg" }), h("span", { class: "pt" }));
  setPill(el, state);
  return el;
}
export function setPill(el, state) {
  const s = STATES[state] || STATES.idle;
  setAttr(el, "data-tone", s.tone);
  setAttr(el, "data-state", state);
  setText(el.firstChild, s.glyph, { flash: false });
  setText(el.lastChild, s.label);
}

export function link(href, text, props = {}) { return h("a", { href, ...props }, text); }
export function whyHref(kind, name, extra = "") { return `#/why/${kind}/${encodeURIComponent(name)}${extra}`; }
export function whyLink(kind, name, text = "why") {
  return h("a", { class: "why-link", href: whyHref(kind, name), "aria-label": `Why ${kind} ${name}` }, text);
}

export function copyButton(text, label = "Copy") {
  const btn = h("button", { type: "button", class: "copy", "aria-label": `${label}: ${text}` }, "Copy");
  btn.addEventListener("click", async () => {
    let ok = false;
    try { await navigator.clipboard.writeText(text); ok = true; } catch { ok = fallbackCopy(text); }
    btn.textContent = ok ? "Copied" : "Press Ctrl+C";
    announce(ok ? "Copied to clipboard" : "Select the text and copy it");
    setTimeout(() => { btn.textContent = "Copy"; }, 1600);
  });
  return btn;
}
function fallbackCopy(text) {
  const ta = h("textarea", { class: "sr-only", "aria-hidden": "true" });
  ta.value = text; document.body.append(ta); ta.select();
  let ok = false; try { ok = document.execCommand("copy"); } catch { ok = false; }
  ta.remove(); return ok;
}

/** A runnable command with a copy button. */
export function command(cmd) {
  return h("div", { class: "cmd" }, h("code", { class: "cmd-text", tabindex: "0" }, h("span", { class: "prompt", "aria-hidden": "true" }, "$ "), cmd), copyButton(cmd, "Copy command"));
}

/** How a change is made: the console is read-only, so say what to run. */
export function howTo(text, cmd) {
  return h("div", { class: "howto" }, h("span", { class: "howto-t" }, text), command(cmd));
}

let announcer = null;
let announceTimer = 0;
let queued = "";
export function announce(msg) {
  announcer = announcer || document.getElementById("announcer");
  if (!announcer) return;
  queued = msg;
  if (announceTimer) return;
  announceTimer = setTimeout(() => { announcer.textContent = queued; announceTimer = 0; }, 400);
}

export function emptyState(title, body, cmd) {
  return h("div", { class: "empty" }, h("p", { class: "empty-t" }, title), body && h("p", { class: "muted" }, body), cmd && command(cmd));
}
