// Entry point of the mock: build the engine for a scenario, drive virtual time from a ticker,
// and hand back a transport the console's API client can use in place of fetch.

import { Engine } from "./engine.js";
import { Runner } from "./scenarios.js";
import { createMockTransport } from "./transport.js";

const TICK_MS = 50;

export function startMock({ scenario = "c0", at = 0, speed = 1, backend = "postgres" } = {}) {
  const engine = new Engine({ backend });
  engine.speed = speed;
  const faults = { apiDown: false };
  const runner = new Runner(engine, faults, scenario);
  runner.fastForward(at);
  let paused = false;
  const ticker = setInterval(() => { if (!paused) engine.advance(TICK_MS * engine.speed); }, TICK_MS);
  return {
    engine, runner, faults,
    transport: createMockTransport(engine, faults),
    get paused() { return paused; },
    setPaused(p) { paused = p; },
    stop() { clearInterval(ticker); },
  };
}
