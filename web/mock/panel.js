// The dev-only scenario panel: play, step, reset, and faults. It doubles as a demo tool.
// Only loaded when the mock is on.
import { h, $, setText } from "../js/ui.js";

export function mountPanel(mock) {
  let open = false;
  let follow = false;
  const stepsEl = h("ol", { class: "steps", "aria-label": "Scenario steps" });
  const status = h("span", { class: "dim", role: "status" });
  const title = h("span", { class: "grow" });
  const barBtn = h("button", { type: "button", class: "dev-bar", "aria-expanded": "false", "aria-controls": "dev-body" },
    h("span", { class: "tag" }, "Mock"), title, status, h("span", { "aria-hidden": "true" }, "▴"));
  const btn = (label, fn, props = {}) => h("button", { type: "button", class: "sm", onclick: fn, ...props }, label);
  const go = step => { if (follow && step?.go) location.hash = step.go; };
  const playBtn = btn("Play", () => (mock.runner.playing ? mock.runner.pause() : mock.runner.play(go)));
  const stepBtn = btn("Step", () => go(mock.runner.step()));
  const resetBtn = btn("Reset", () => mock.reset(mock.runner.name, 0));
  const storeBtn = btn("Stop Postgres", () => mock.runner.setStoreUp(!mock.engine.storeUp), { "aria-pressed": "false" });
  const apiBtn = btn("Cut API", () => mock.runner.setApiDown(!mock.faults.apiDown), { "aria-pressed": "false" });
  const sleepBtn = btn("Sleep + compact", () => mock.runner.sleepAndCompact());
  const pauseBtn = btn("Freeze time", () => { mock.setPaused(!mock.paused); sync(true); }, { "aria-pressed": "false" });
  const scenario = h("select", { id: "dev-scenario", "aria-label": "Scenario", class: "sm" }, ...Object.entries(mock.scenarios).map(([k, t]) => h("option", { value: k }, t)));
  scenario.addEventListener("change", () => mock.reset(scenario.value, 0));
  const speed = h("select", { id: "dev-speed", "aria-label": "Speed", class: "sm" }, ...[1, 2, 4, 8].map(v => h("option", { value: v }, `${v}×`)));
  speed.value = String(mock.speed);
  speed.addEventListener("change", () => { mock.speed = Number(speed.value); mock.engine.speed = mock.speed; });
  const followBox = h("input", { type: "checkbox", id: "dev-follow" });
  followBox.addEventListener("change", () => { follow = followBox.checked; });
  const body = h("div", { class: "dev-body", id: "dev-body", hidden: true },
    h("div", { class: "dev-row" }, scenario, speed),
    h("div", { class: "dev-row" }, playBtn, stepBtn, resetBtn),
    h("label", { class: "chk" }, followBox, " Open the matching screen on each step"),
    stepsEl,
    h("div", { class: "dev-row" }, storeBtn, apiBtn, sleepBtn, pauseBtn),
    h("p", { class: "dim", style: "font-size:.75rem" }, "Mock data only: the API shape of docs/api.md, served from this page. Reset starts the scenario from an empty cluster."));
  const el = h("aside", { class: "dev", "aria-label": "Scenario controls (mock only)" }, barBtn, body);
  document.body.append(el);
  $("#env-tag").textContent = "mock";
  barBtn.addEventListener("click", () => { open = !open; body.hidden = !open; barBtn.setAttribute("aria-expanded", String(open)); });

  function sync(force) {
    const { runner, engine } = mock;
    const steps = runner.def.steps;
    const sig = [runner.name, runner.index, runner.playing, engine.storeUp, mock.faults.apiDown, mock.paused].join("|");
    if (!force && el._sig === sig) return;
    el._sig = sig;
    stepsEl.replaceChildren(...steps.map((s, i) => h("li", { "data-s": i < runner.index ? "done" : i === runner.index ? "next" : "todo", "aria-current": i === runner.index ? "step" : null },
      h("span", { "aria-hidden": "true" }, i < runner.index ? "✓" : i === runner.index ? "▸" : "·"), h("span", {}, s.title, h("code", {}, s.cli)))));
    setText(title, runner.def.title, { flash: false });
    setText(status, runner.index >= steps.length ? "done" : `step ${runner.index + 1}/${steps.length}`, { flash: false });
    scenario.value = runner.name;
    playBtn.textContent = runner.playing ? "Pause" : runner.index >= steps.length ? "Finished" : "Play";
    playBtn.disabled = stepBtn.disabled = runner.index >= steps.length;
    storeBtn.textContent = engine.storeUp ? "Stop Postgres" : "Start Postgres"; storeBtn.setAttribute("aria-pressed", String(!engine.storeUp));
    apiBtn.textContent = mock.faults.apiDown ? "Restore API" : "Cut API"; apiBtn.setAttribute("aria-pressed", String(!!mock.faults.apiDown));
    pauseBtn.setAttribute("aria-pressed", String(mock.paused));
  }
  const bind = () => { mock.runner.onChange(sync); sync(true); };
  mock.resetListeners.add(bind);
  bind();
}
