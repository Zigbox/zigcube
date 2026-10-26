// Entry point of the mock: build the engine for a scenario, drive virtual time from a ticker,
// and hand back a transport the console's API client can use in place of fetch.
// `reset()` rebuilds everything in place; the console notices the revision went backwards
// (ZC-E0204), lists again and carries on, exactly as it would after a server restart.

import { Engine } from "./engine.js";
import { Runner, SCENARIOS } from "./scenarios.js";
import { createMockTransport } from "./transport.js";

const TICK_MS = 50;

export function startMock({ scenario = "c0", at = 0, speed = 1, backend = "postgres" } = {}) {
  const mock = {
    scenarios: Object.fromEntries(Object.entries(SCENARIOS).map(([k, v]) => [k, v.title])),
    paused: false,
    speed,
    backend,
    faults: { apiDown: false },
    setPaused(p) { mock.paused = p; },
    build(name, upTo) {
      mock.engine = new Engine({ backend: mock.backend });
      mock.engine.speed = mock.speed;
      mock.faults.apiDown = false;
      mock.runner = new Runner(mock.engine, mock.faults, name);
      mock.runner.fastForward(upTo);
      mock.api = createMockTransport(mock.engine, mock.faults);
    },
    reset(name = mock.runner.name, upTo = 0) {
      const old = mock.engine;
      mock.runner.pause();
      old.dead = true; // requests still waiting on the old engine fail like a restarted server's connections
      for (const wake of [...old.waiters]) wake();
      mock.build(name, upTo); for (const fn of [...mock.resetListeners]) fn(); },
    resetListeners: new Set(),
    request: (...args) => mock.api.request(...args),
    stop() { clearInterval(ticker); },
  };
  mock.build(scenario, at);
  const ticker = setInterval(() => { if (!mock.paused) mock.engine.advance(TICK_MS * mock.speed); }, TICK_MS);
  return mock;
}
