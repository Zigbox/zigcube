// Scenarios replay HANDOFF's demos against the engine. A step has the CLI line it stands for, a
// `run(engine, ctl)` that does what that line would do, and optionally a console view to open.

import { HELLO, BROKEN } from "./fixtures.js";

const helloWith = replicas => ({ ...HELLO, replicas });

export const SCENARIOS = {
  c0: {
    title: "C0 · Loop (one node)",
    setup(engine) { engine.addAgent("node1"); },
    steps: [
      { title: "Apply hello with 3 replicas", cli: "zcube apply hello.zon", go: "#/services/hello", run: e => e.apply(helloWith(3)) },
      { title: "kill -9 one replica", cli: "kill -9 $(pgrep -f hello-2)", go: "#/why/service/hello", run: e => e.kill("hello-2") },
      { title: "Scale to 5", cli: "zcube apply hello.zon   # replicas = 5", go: "#/replicas", run: e => e.apply(helloWith(5)) },
      { title: "Scale back to 2", cli: "zcube apply hello.zon   # replicas = 2", go: "#/services/hello", run: e => e.apply(helloWith(2)) },
      { title: "Apply broken (digest not in fixtures)", cli: "zcube apply broken.zon && zcube why service broken", go: "#/why/service/broken", run: e => e.apply({ ...BROKEN, replicas: 1 }) },
      { title: "Postgres goes down", cli: "pg_ctl stop && zcube get service hello", go: "#/", run: (e, c) => c.setStoreUp(false) },
      { title: "Postgres comes back", cli: "pg_ctl start", go: "#/", run: (e, c) => c.setStoreUp(true) },
    ],
  },
  c1: {
    title: "C1 · Fleet (three nodes)",
    setup() {},
    steps: [
      { title: "Three agents join", cli: "zcube get nodes", go: "#/nodes", run: e => { for (const n of ["node1", "node2", "node3"]) e.addAgent(n); } },
      { title: "Apply hello with 6 replicas", cli: "zcube apply hello.zon && zcube get replicas -o wide", go: "#/replicas", run: e => e.apply(helloWith(6)) },
      { title: "Power off node3 (lease expires after 10 s)", cli: "# node3 loses power", go: "#/nodes", run: e => e.powerOff("node3") },
      { title: "Restart node3's agent; it rejoins empty", cli: "zcube-agent --node node3", go: "#/nodes", run: e => e.powerOn("node3") },
      { title: "Ask why nothing moved back", cli: "zcube why node node3", go: "#/why/node/node3", run: () => {} },
    ],
  },
};

/** Runs steps and exposes the controls the dev panel needs. */
export class Runner {
  constructor(engine, faults, name) {
    this.engine = engine;
    this.faults = faults;
    this.def = SCENARIOS[name];
    this.name = name;
    this.index = 0; // next step to run
    this.playing = false;
    this.listeners = new Set();
    this.def.setup(engine);
  }
  onChange(fn) { this.listeners.add(fn); }
  emit() { for (const fn of this.listeners) fn(); }

  setStoreUp(up) { this.engine.setStoreUp(up); this.emit(); }
  setApiDown(down) {
    this.faults.apiDown = down;
    if (down) for (const wake of [...this.engine.waiters]) wake();
    this.emit();
  }

  step() {
    if (this.index >= this.def.steps.length) return null;
    const step = this.def.steps[this.index++];
    step.run(this.engine, this);
    this.engine.activeUntil = Math.max(this.engine.activeUntil, this.engine.t + 1500);
    this.emit();
    return step;
  }

  /** Runs steps up to `n` and settles, without waiting in real time. */
  fastForward(n) {
    this.engine.settle();
    while (this.index < Math.min(n, this.def.steps.length)) { this.step(); this.engine.settle(); }
    this.emit();
  }

  async play(onStep) {
    if (this.playing) return;
    this.playing = true; this.emit();
    while (this.playing && this.index < this.def.steps.length) {
      const step = this.step();
      onStep?.(step);
      await this.waitSettled();
      for (let i = 0; i < 20 && this.playing; i++) await new Promise(r => setTimeout(r, 100)); // a beat to read
    }
    this.playing = false; this.emit();
  }
  pause() { this.playing = false; this.emit(); }

  waitSettled() {
    return new Promise(resolve => {
      const poll = () => (!this.playing || this.engine.settled() ? resolve() : setTimeout(poll, 100));
      poll();
    });
  }

  /** Console-failure fixtures: the console is cut off, history is compacted meanwhile, then it returns. */
  sleepAndCompact() {
    this.setApiDown(true);
    setTimeout(() => {
      const e = this.engine;
      const svc = e.values("/services/")[0];
      if (svc) { e.apply({ ...svc, replicas: svc.replicas + 1 }); e.apply({ ...svc }); }
      e.advance(1500);
      e.compact(e.rev);
      this.setApiDown(false);
    }, 3500 / (this.engine.speed || 1));
  }
}
