// The mock has the C1 and B1 scenarios: the core has no C1 yet (C0 runs the real core, web/sim/), and sim mode has no jobs.
// Scenarios replay HANDOFF's demos against the engine. A step has the CLI line it stands for, a
// `run(engine, ctl)` that does what that line would do, and optionally a console view to open.

import { HELLO, diagImageNotFound } from "./fixtures.js";

const helloWith = replicas => ({ ...HELLO, replicas });

export const SCENARIOS = {
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

// `?mock=c1-compacted`: the C1 run, then the service is scaled and the store compacted, so the
// replicas' causes (the old /services/hello) are gone: `why replica hello-1` ends `compacted`.
SCENARIOS["c1-compacted"] = {
  title: "C1 · Fleet, then compaction",
  setup() {},
  steps: [
    ...SCENARIOS.c1.steps.slice(0, 2),
    { title: "Scale hello and compact the store", cli: "zcube scale hello 7 # then the store compacts", go: "#/why/replica/hello-1", run: e => { e.apply(helloWith(7)); e.advance(1500); e.compact(e.rev); } },
  ],
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

// `?mock=b1`: B1's jobs (docs/briefs/b1.md). Every state and every ending cause of the closed set,
// so the Jobs screen can be seen in each. A plan is the mock's own script for a run (web/mock/jobs.js).
const JOB = { image: "b3:51aa9c03", command: ["run", "--epochs", "3"], env: [["MODE", "fast"], ["API_TOKEN", "s3cr3t-token"]], limits: { cpu_millis: 500, memory_bytes: 268435456, pids: 64 }, deadline_ms: 600000, grace_ms: 5000 };
const BAD = "b3:00000000"; // not in KNOWN_IMAGES: the fake runtime cannot start it
const submit = (e, name, over = {}, plan = {}) => e.jobs.submit({ ...JOB, name, submit_by_ms: e.now() + 3600000, labels: [["team", "ml"]], applied_by: "alex@laptop", ...over }, plan);
const failed = (cause, extra = {}) => ({ outcome: { kind: "failed", cause }, ...extra });

SCENARIOS.b1 = {
  title: "B1 · Jobs (every state and ending)",
  setup() {},
  steps: [
    { title: "Three agents join", cli: "zcube get nodes", go: "#/nodes", run: e => { for (const n of ["node1", "node2", "node3"]) e.addAgent(n); } },
    { title: "Submit jobs that end every way", cli: "zcube job submit train.zon  # and sixteen more", go: "#/jobs", run: e => {
      submit(e, "train-ok", { labels: [["team", "ml"], ["kind", "train"]], input: "epochs=3\n", input_env: "TRAIN_INPUT" }, { node: "node1", run: 2500 });
      submit(e, "export-exit3", {}, { node: "node2", run: 2000, outcome: { kind: "exited", code: 3 } });
      submit(e, "probe-sigkill", { labels: [["team", "infra"]] }, { node: "node3", run: 2200, outcome: { kind: "exited", signal: 9 } });
      submit(e, "fit-oom", {}, { node: "node1", run: 3000, ...failed("oom") });
      submit(e, "fork-bomb", {}, { node: "node2", run: 1800, ...failed("pid_limit") });
      submit(e, "bad-image", { image: BAD }, { node: "node3", start: 800, run: 500, ...failed("start_failed", { diagnostic: diagImageNotFound(BAD, "node3", "bad-image-job") }) });
      submit(e, "slow-merge", { deadline_ms: 6000 }, { node: "node1", run: 5000, ...failed("deadline") });
      submit(e, "fenced-write", {}, { node: "node2", run: 4000, ...failed("fenced") });
      submit(e, "lost-node", {}, { node: "node3", run: 4500, ...failed("unreachable") });
      submit(e, "never-started", {}, { node: "node1", start: 500, outcome: { kind: "failed", cause: "not_started", never_started: true } });
      submit(e, "mystery", {}, { node: "node2", run: 2600, ...failed("unknown") });
      submit(e, "no-room", { deadline_ms: 9000 }, { hold: 9000 });
      submit(e, "run-forever", { labels: [["team", "ml"], ["kind", "serve"]] }, { node: "node1", run: null });
      submit(e, "placed-wait", {}, { node: "node2", start: null });
      submit(e, "waiting", { labels: [["team", "infra"]] }, { hold: 3600000 });
      submit(e, "cancel-running", {}, { node: "node3", run: null });
      submit(e, "cancel-waiting", {}, { hold: 3600000 });
    } },
    { title: "Cancel a running job and a waiting one", cli: "zcube job cancel cancel-running && zcube job cancel cancel-waiting", go: "#/jobs", run: e => { e.jobs.cancel("cancel-running"); e.jobs.cancel("cancel-waiting"); } },
    { title: "Ask why a job failed", cli: "zcube why job fit-oom", go: "#/why/job/fit-oom", run: () => {} },
  ],
};
