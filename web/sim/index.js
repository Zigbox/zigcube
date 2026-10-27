// The console on the real control-plane core: src/console_wasm.zig, loaded as WebAssembly. The
// core's API handlers, controller, agent step and `why` run here over a memory store and a
// simulated runtime, on virtual time. This module is the host: it frames requests, moves the
// clock, holds long-poll watches, and turns a trap into a `bug` diagnostic. It is a simulation
// and says so everywhere it shows itself; nothing it produces is recorded.
//
// The transport has the shape of `fetchTransport`: (method, path, {signal}) -> {status, headers,
// body}. Response bodies are parsed, never rewritten.

const OP = { reset: 0, step: 1, storeDown: 2, compact: 3, restartServer: 4, restartAgent: 5, nextIndex: 6, stepsTotal: 7, isStoreDown: 8 };
const FRAME_MAX = 65536 + 4096; // console_sim.frame_bytes_max
const TICK_MS = 50;
const GAP_MAX_MS = 1000; // a tab that was hidden does not make the world jump
const ADVANCE_MAX_MS = 60000; // zc_advance's limit per call

export const SIM_OPS = OP;

export async function startSim({ speed = 1 } = {}) {
  const url = new URL("./zcube_console.wasm", import.meta.url);
  let response = await fetch(url);
  if (!response.ok) throw new Error(`could not load ${url.pathname}: ${response.status}`);
  const bytes = await response.arrayBuffer();
  const decoder = new TextDecoder(), encoder = new TextEncoder();
  const sim = { speed, paused: false, dead: false, panicText: "", faults: { apiDown: false }, listeners: new Set(), waiters: new Set(), generation: 0 };
  let exports = null, lastRev = null, last = performance.now();

  const emit = () => { for (const fn of [...sim.listeners]) fn(); };
  const wakeAll = () => { for (const wake of [...sim.waiters]) wake(); };

  async function instantiate() {
    sim.panicText = "";
    const { instance } = await WebAssembly.instantiate(bytes, { env: { zc_panic(pointer, length) {
      sim.panicText = decoder.decode(new Uint8Array(exports.memory.buffer, pointer, length).slice());
    } } });
    exports = instance.exports;
    if (exports.zc_init() !== 0) throw new Error("zc_init failed");
    lastRev = exports.zc_revision();
  }
  await instantiate();

  /** Runs `fn` against the exports; a trap or any throw discards the instance (docs/wasm.md row 9). */
  function guard(fn) {
    if (sim.dead) return undefined;
    try { return fn(exports); } catch (error) {
      sim.dead = true;
      sim.error = error;
      clearInterval(ticker);
      wakeAll(); emit();
      return undefined;
    }
  }

  function bugDiagnostic() {
    const cause = sim.panicText || `the module stopped without a message (${sim.error?.message || "unknown"})`;
    return {
      code: "ZC-B0001", severity: "bug", blame: "internal",
      summary: "the simulated control plane hit an internal error",
      causes: [cause, "the in-browser store was part of that instance and is lost with it; reload the page to start the scenario again"],
      while: [], context: {}, fixes: [], omitted: { causes: 0, while: 0, context: 0, fixes: 0 },
    };
  }

  function revisionChanged() {
    const rev = guard(e => e.zc_revision());
    if (rev !== lastRev) { lastRev = rev; wakeAll(); }
  }

  /** One request to the core. Returns {status, id, text, hold}. */
  function call(method, path, query) {
    const frame = encoder.encode(`${method}\0${path}\0${query}\0\0`);
    if (frame.length > FRAME_MAX) throw new TypeError("request too large");
    return guard(e => {
      new Uint8Array(e.memory.buffer, e.zc_request_ptr(), frame.length).set(frame);
      const status = e.zc_request(frame.length);
      const view = (ptr, len) => decoder.decode(new Uint8Array(e.memory.buffer, ptr, len).slice());
      return { status, id: view(e.zc_response_id_ptr(), e.zc_response_id_len()), text: view(e.zc_response_ptr(), e.zc_response_len()), hold: e.zc_response_hold_ms() };
    });
  }

  function reply(status, body, id) {
    return { status, headers: { "x-request-id": id, "content-type": "application/json" }, body };
  }
  function deadReply() { return reply(500, { request_id: "", diagnostics: [bugDiagnostic()] }, ""); }

  async function request(method, url, { signal } = {}) {
    if (sim.faults.apiDown) throw new TypeError("Failed to fetch");
    if (signal?.aborted) throw new DOMException("aborted", "AbortError");
    await Promise.resolve();
    const u = new URL(url, "http://sim.local");
    let query = u.search.replace(/^\?/, "");
    let deadline = null;
    for (;;) {
      if (sim.faults.apiDown) throw new TypeError("Failed to fetch");
      const r = call(method, u.pathname, query);
      if (!r) return deadReply();
      if (!r.hold) return reply(r.status, r.text ? JSON.parse(r.text) : null, r.id);
      deadline ??= performance.now() + r.hold;
      const left = deadline - performance.now();
      if (left <= 0) { query = query.replace(/(^|&)timeout=\d+/, "$1timeout=0"); continue; }
      await new Promise((resolve, reject) => {
        const done = () => { cleanup(); resolve(); };
        const timer = setTimeout(done, left);
        const onAbort = () => { cleanup(); reject(new DOMException("aborted", "AbortError")); };
        const cleanup = () => { clearTimeout(timer); sim.waiters.delete(done); signal?.removeEventListener("abort", onAbort); };
        sim.waiters.add(done);
        signal?.addEventListener("abort", onAbort);
      });
    }
  }

  // ---- Time ----
  function advance(ms) {
    while (ms > 0 && !sim.dead) { const piece = Math.min(ms, ADVANCE_MAX_MS); guard(e => e.zc_advance(piece)); ms -= piece; }
    revisionChanged();
  }
  const ticker = setInterval(() => {
    const now = performance.now();
    const gap = Math.min(now - last, GAP_MAX_MS);
    last = now;
    if (!sim.paused && !document.hidden) advance(Math.round(gap * sim.speed));
  }, TICK_MS);

  // ---- Controls ----
  function control(op, arg = 0) {
    const result = guard(e => e.zc_control(op, arg));
    revisionChanged(); emit();
    return result;
  }
  Object.assign(sim, {
    request, control, advance, bugDiagnostic,
    onChange: fn => sim.listeners.add(fn),
    setPaused(p) { sim.paused = p; last = performance.now(); emit(); },
    setApiDown(down) { sim.faults.apiDown = down; if (down) wakeAll(); emit(); },
    nextIndex() { const n = guard(e => e.zc_control(OP.nextIndex, 0)); if (n !== undefined) sim.lastIndex = n; return sim.lastIndex ?? 0; }, // kept after a trap, so the panel still shows where it stopped
    stepsTotal: () => guard(e => e.zc_control(OP.stepsTotal, 0)) ?? 0,
    storeDown: () => guard(e => e.zc_control(OP.isStoreDown, 0)) === 1,
    nowMs: () => guard(e => e.zc_now_ms()) ?? 0,
    step: () => control(OP.step),
    reset() { sim.faults.apiDown = false; return control(OP.reset); },
    setStoreDown: down => control(OP.storeDown, down ? 1 : 0),
    /** Cuts the API, lets the core write and compact its history meanwhile, then restores it: the
     *  console's watch then asks for a revision the core really has dropped (410, ZC-E0203). */
    sleepAndCompact() {
      sim.setApiDown(true);
      setTimeout(() => {
        control(OP.restartAgent); // registers again: a write, so there is history to compact
        advance(1500);
        control(OP.compact);
        sim.setApiDown(false);
      }, 3500 / sim.speed);
    },
    /** Test hook: breaks the doorway's own assertion, as a bug in the core would. */
    forcePanic() { guard(e => e.zc_request(0x7fffffff)); },
    stop() { clearInterval(ticker); },
  });
  return sim;
}
