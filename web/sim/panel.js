// The dev panel of the simulated console: play, step, reset, and faults, driving the real core.
// Same look as the mock's panel (web/mock/panel.js). Loaded only for ?sim=c0.
import { h, $, setText } from "../js/ui.js";
import { SCENARIO } from "./scenario.js";

export function mountSimPanel(sim) {
  let open = false, follow = false, playing = false;
  const stepsEl = h("ol", { class: "steps", "aria-label": "Scenario steps" });
  const status = h("span", { class: "dim", role: "status" });
  const title = h("span", { class: "grow" }, SCENARIO.title);
  const barBtn = h("button", { type: "button", class: "dev-bar", "aria-expanded": "false", "aria-controls": "dev-body" },
    h("span", { class: "tag" }, "Simulated"), title, status, h("span", { "aria-hidden": "true" }, "▴"));
  const btn = (label, fn, props = {}) => h("button", { type: "button", class: "sm", onclick: fn, ...props }, label);
  const total = SCENARIO.steps.length;
  const go = index => { if (follow && SCENARIO.steps[index]?.go) location.hash = SCENARIO.steps[index].go; };
  const runStep = () => { const index = sim.step(); if (index >= 0) go(index); return index; };
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  async function play() {
    if (playing) return;
    playing = true; sync(true);
    while (playing && !sim.dead && sim.nextIndex() < total) {
      const index = runStep();
      if (index < 0) break;
      const until = sim.nowMs() + SCENARIO.steps[index].wait * 1000; // virtual time for the controllers to act
      while (playing && !sim.dead && sim.nowMs() < until) await sleep(100);
      for (let i = 0; i < 10 && playing; i++) await sleep(100); // a beat to read
    }
    playing = false; sync(true);
  }

  const playBtn = btn("Play", () => { if (playing) { playing = false; sync(true); } else play(); });
  const stepBtn = btn("Step", runStep);
  const resetBtn = btn("Reset", () => { playing = false; sim.reset(); });
  const storeBtn = btn("Stop store", () => sim.setStoreDown(!sim.storeDown()), { "aria-pressed": "false" });
  const apiBtn = btn("Cut API", () => sim.setApiDown(!sim.faults.apiDown), { "aria-pressed": "false" });
  const sleepBtn = btn("Sleep + compact", () => sim.sleepAndCompact());
  const serverBtn = btn("Restart server core", () => sim.control(4));
  const agentBtn = btn("Restart agent core", () => sim.control(5));
  const pauseBtn = btn("Freeze time", () => { sim.setPaused(!sim.paused); }, { "aria-pressed": "false" });
  const speed = h("select", { id: "dev-speed", "aria-label": "Speed", class: "sm" }, ...[1, 2, 4, 8].map(v => h("option", { value: v }, `${v}×`)));
  speed.value = String(sim.speed);
  speed.addEventListener("change", () => { sim.speed = Number(speed.value); });
  const followBox = h("input", { type: "checkbox", id: "dev-follow" });
  followBox.addEventListener("change", () => { follow = followBox.checked; });
  const body = h("div", { class: "dev-body", id: "dev-body", hidden: true },
    h("div", { class: "dev-row" }, speed),
    h("div", { class: "dev-row" }, playBtn, stepBtn, resetBtn),
    h("label", { class: "chk" }, followBox, " Open the matching screen on each step"),
    stepsEl,
    h("div", { class: "dev-row" }, storeBtn, apiBtn, sleepBtn, pauseBtn),
    h("div", { class: "dev-row" }, serverBtn, agentBtn),
    h("p", { class: "dim", style: "font-size:.75rem" }, "A simulation of the real control-plane core, running in your browser on virtual time: its controllers, API handlers and `why` are the server's own code compiled to WebAssembly, over a memory store and a simulated runtime. Nothing here is recorded, no process is started, and a reload starts over from an empty cluster."));
  const el = h("aside", { class: "dev", "aria-label": "Scenario controls (simulation)" }, barBtn, body);
  document.body.append(el);
  $("#env-tag").textContent = "simulated";
  barBtn.addEventListener("click", () => { open = !open; body.hidden = !open; barBtn.setAttribute("aria-expanded", String(open)); });

  function sync(force) {
    const index = sim.nextIndex();
    const sig = [index, playing, sim.storeDown(), sim.faults.apiDown, sim.paused, sim.dead].join("|");
    if (!force && el._sig === sig) return;
    el._sig = sig;
    stepsEl.replaceChildren(...SCENARIO.steps.map((s, i) => h("li", { "data-s": i < index ? "done" : i === index ? "next" : "todo", "aria-current": i === index ? "step" : null },
      h("span", { "aria-hidden": "true" }, i < index ? "✓" : i === index ? "▸" : "·"), h("span", {}, s.title, h("code", {}, s.cli)))));
    setText(status, sim.dead ? "stopped" : index >= total ? "done" : `step ${index + 1}/${total}`, { flash: false });
    playBtn.textContent = playing ? "Pause" : index >= total ? "Finished" : "Play";
    playBtn.disabled = stepBtn.disabled = index >= total || sim.dead;
    storeBtn.textContent = sim.storeDown() ? "Start store" : "Stop store"; storeBtn.setAttribute("aria-pressed", String(sim.storeDown()));
    apiBtn.textContent = sim.faults.apiDown ? "Restore API" : "Cut API"; apiBtn.setAttribute("aria-pressed", String(!!sim.faults.apiDown));
    pauseBtn.setAttribute("aria-pressed", String(sim.paused));
    for (const b of [resetBtn, storeBtn, apiBtn, sleepBtn, serverBtn, agentBtn, pauseBtn]) b.disabled = sim.dead;
  }
  sim.onChange(() => sync());
  sync(true);
}
