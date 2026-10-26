// Pieces shared by several views. Each `make*` returns {el, update(...)} so `keyed` can reuse it.
import { h, setText, setAttr, pill, setPill, whyLink, whyHref, timeEl, cpu, mem } from "../ui.js";

export function pageHead(title, sub, ...actions) {
  return h("div", { class: "page-head" }, h("div", {}, h("h1", { tabindex: "-1", id: "page-title" }, title), sub && h("p", { class: "sub" }, sub)), actions.length ? h("div", { class: "page-actions" }, ...actions) : null);
}

/** Replica states as a segmented bar with the numbers beside it. */
export function makeReplicaBar() {
  const seg = cls => h("span", { class: `seg ${cls}` });
  const segs = { ok: seg("ok"), info: seg("info"), err: seg("err"), gap: seg("gap") };
  const bar = h("span", { class: "rbar", role: "img" }, ...Object.values(segs));
  const num = h("span", { class: "rnum" });
  const el = h("span", { class: "rep" }, num, bar);
  return {
    el,
    update(c, desired) {
      const info = c.starting + c.pending + c.unscheduled;
      const err = c.failed + c.lost;
      const total = Math.max(desired, c.running + info + err + c.stopped);
      segs.ok.style.flexGrow = c.running; segs.info.style.flexGrow = info; segs.err.style.flexGrow = err + c.stopped;
      segs.gap.style.flexGrow = Math.max(0, total - c.running - info - err - c.stopped);
      setText(num, `${c.running}/${desired}`);
      setAttr(bar, "aria-label", `${c.running} running, ${info} starting, ${err} failed or lost, of ${desired} wanted`);
    },
  };
}

/** A horizontal meter: used of capacity, with text. */
export function makeMeter(format, { lease = false } = {}) {
  const fill = h("span", { class: "fill" });
  const track = h("span", { class: "track", role: "img" }, fill);
  const text = h("span", { class: "mtext" });
  return {
    el: h("span", { class: "meter" }, track, text),
    update(used, cap) {
      const pct = cap ? Math.min(100, (used / cap) * 100) : 0;
      fill.style.width = pct + "%";
      setAttr(fill.parentElement, "data-high", (lease ? pct <= 50 : pct >= 85) ? "1" : null);
      setText(text, cap == null ? "–" : lease ? `${format(used)} left of ${format(cap)}` : `${format(used)} / ${format(cap)}`);
      setAttr(track, "aria-label", cap == null ? "no capacity declared" : `${Math.round(pct)}% used`);
    },
  };
}

export const cpuMeter = () => makeMeter(cpu);
export const memMeter = () => makeMeter(mem);

export function makeDecisionItem() {
  const when = h("span", { class: "d-when" });
  const actor = h("span", { class: "d-actor" });
  const subject = h("a", { class: "d-subject" });
  const reason = h("span", { class: "d-reason" });
  const el = h("li", { class: "decision" }, when, h("span", { class: "d-main" }, h("span", { class: "d-head" }, actor, subject), reason));
  let ts = 0;
  return {
    el,
    update(d) {
      if (ts !== d.at_ms) { ts = d.at_ms; when.replaceChildren(timeEl(d.at_ms)); }
      setText(actor, `${d.actor} · ${d.action}`, { flash: false });
      setText(subject, `${d.subject.kind} ${d.subject.name}`, { flash: false });
      setAttr(subject, "href", whyHref(d.subject.kind, d.subject.name, `?decision=${d.id}`));
      setText(reason, d.reason, { flash: false });
    },
  };
}

export function nameLink(kind, name) {
  const href = kind === "replica" ? whyHref("replica", name) : `#/${kind}s/${encodeURIComponent(name)}`;
  return h("a", { class: "name", href }, name);
}

export { pill, setPill, whyLink };
