// The dev-only scenario panel: play, step, reset, and faults. It doubles as a demo tool.
// Only loaded when the mock is on.
import { h, $, setText, clear } from "../js/ui.js";

export function mountPanel(mock, ctx) {
  const { runner, engine } = mock;
  let open = false;
  let follow = false;
  const stepsEl = h("ol", { class: "steps", "aria-label": "Scenario steps" });
  const status = h("span", { class: "dim", role: "status" });
  const barBtn = h("button", { type: "button", class: "dev-bar", "aria-expanded": "false", "aria-controls": "dev-body" },
    h("span", { class: "tag" }, "Mock"), h("span", { class: "grow" }, runner.def.title), status, h("span", { "aria-hidden": "true" }, "▴"));
  const btn = (label, fn, props = {}) => h("button", { type: "button", class: "sm", onclick: fn, ...props }, label);
  const playBtn = btn("Play", () => (runner.playing ? runner.pause() : runner.play(go)));
  const stepBtn = btn("Step", () => go(runner.step()));
  const resetBtn = btn("Reset", () => { const q = new URLSearchParams(location.search); q.set("mock", runner.name); q.delete("at"); q.set("at", "0"); location.href = `${location.pathname}?${q}${location.hash}`; });
  const storeBtn = btn("Stop Postgres", () => runner.setStoreUp(!engine.storeUp), { "aria-pressed": "false" });
  const apiBtn = btn("Cut API", () => runner.setApiDown(!mock.faults.apiDown), { "aria-pressed": "false" });
  const sleepBtn = btn("Sleep + compact", () => runner.sleepAndCompact());
  const pauseBtn = btn("Freeze time", () => { mock.setPaused(!mock.paused); sync(); }, { "aria-pressed": "false" });
  const speed = h("select", { id: "dev-speed", "aria-label": "Speed", class: "sm" }, ...[1, 2, 4, 8].map(v => h("option", { value: v }, `${v}×`)));
  speed.value = String(engine.speed);
  speed.addEventListener("change", () => { engine.speed = Number(speed.value); });
  const followBox = h("input", { type: "checkbox", id: "dev-follow" });
  followBox.addEventListener("change", () => { follow = followBox.checked; });
  const body = h("div", { class: "dev-body", id: "dev-body", hidden: true },
    h("div", { class: "dev-row" }, playBtn, stepBtn, resetBtn, speed),
    h("label", { class: "chk" }, followBox, " Open the matching screen on each step"),
    stepsEl,
    h("div", { class: "dev-row" }, storeBtn, apiBtn, sleepBtn, pauseBtn),
    h("p", { class: "dim", style: "font-size:.75rem" }, "Mock data only. The same API shape as docs/api.md, served from this page. Add ?mock=c1 for the fleet scenario."));
  const el = h("aside", { class: "dev", "aria-label": "Scenario controls (mock only)" }, barBtn, body);
  document.body.append(el);
  $("#env-tag").textContent = `mock · ${runner.name}`;
  barBtn.addEventListener("click", () => { open = !open; body.hidden = !open; barBtn.setAttribute("aria-expanded", String(open)); });

  function go(step) { if (follow && step?.go) location.hash = step.go; }
  function sync() {
    const steps = runner.def.steps;
    const sig = runner.index + "|" + runner.playing + "|" + engine.storeUp + "|" + mock.faults.apiDown + "|" + mock.paused;
    if (el._sig === sig) return;
    el._sig = sig;
    stepsEl.replaceChildren(...steps.map((s, i) => h("li", { "data-s": i < runner.index ? "done" : i === runner.index ? "next" : "todo", "aria-current": i === runner.index ? "step" : null },
      h("span", { "aria-hidden": "true" }, i < runner.index ? "✓" : i === runner.index ? "▸" : "·"), h("span", {}, s.title, h("code", {}, s.cli)))));
    setText(status, runner.index >= steps.length ? "done" : `step ${runner.index + 1}/${steps.length}`, { flash: false });
    playBtn.textContent = runner.playing ? "Pause" : runner.index >= steps.length ? "Finished" : "Play";
    playBtn.disabled = stepBtn.disabled = runner.index >= steps.length;
    storeBtn.textContent = engine.storeUp ? "Stop Postgres" : "Start Postgres"; storeBtn.setAttribute("aria-pressed", String(!engine.storeUp));
    apiBtn.textContent = mock.faults.apiDown ? "Restore API" : "Cut API"; apiBtn.setAttribute("aria-pressed", String(!!mock.faults.apiDown));
    pauseBtn.setAttribute("aria-pressed", String(mock.paused));
  }
  runner.onChange(sync);
  sync();
  window.addEventListener("hashchange", () => {});
}
