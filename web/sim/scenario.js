// The C0 scenario of the simulated console: seven steps, keyed to the core's step indexes
// (src/console_sim.zig, `scenario_steps`). The core does the work; this is what the panel shows.
// `wait` is the virtual seconds the player lets pass after the step so the controllers can act.

export const SCENARIO = {
  title: "C0 · Loop (one node)",
  steps: [
    { title: "Apply hello with 3 replicas", cli: "zcube apply hello.zon", go: "#/services/hello", wait: 3 },
    { title: "kill -9 one replica", cli: "kill -9 $(pgrep -f hello-1)", go: "#/why/service/hello", wait: 3 },
    { title: "Scale to 5", cli: "zcube apply hello.zon   # replicas = 5", go: "#/replicas", wait: 3 },
    { title: "Scale back to 2", cli: "zcube apply hello.zon   # replicas = 2", go: "#/services/hello", wait: 10 },
    { title: "Apply broken (digest not in fixtures)", cli: "zcube apply broken.zon && zcube why service broken", go: "#/why/service/broken", wait: 3 },
    { title: "The store goes down", cli: "pg_ctl stop && zcube get service hello", go: "#/", wait: 1 },
    { title: "The store comes back", cli: "pg_ctl start", go: "#/", wait: 3 },
  ],
};
