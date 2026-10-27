// Checks the console's browser module (zig build console-wasm):
//
//   node tools/console_check.mjs <zcube_console.wasm>
//
// It fails unless the module (1) imports exactly one function, env.zc_panic, and nothing else;
// (2) starts, answers GET /v1/status and runs the whole C0 scenario to the story the console
// tells (hello at 2 running, broken explained by ZBX-E0501, the store down and back); and (3)
// reports a panic through its one import before it traps. Why JavaScript, and why Node twice (one
// run per V8 compiler): docs/wasm.md, "Why JavaScript for the runner" and "Node 22 crashes when
// V8 mixes its compiler tiers". This file holds no logic of the core: it writes request frames
// and compares what comes back.

import { readFileSync } from "node:fs";

const path = process.argv[2];
if (!path) {
  console.error("usage: node tools/console_check.mjs <zcube_console.wasm>");
  process.exit(2);
}
const bytes = readFileSync(path);

function fail(message) {
  console.error(`console check: ${message}`);
  process.exit(1);
}

// ---- (1) The imports: exactly one, by name ------------------------------------------------------

const module = new WebAssembly.Module(bytes);
const imports = WebAssembly.Module.imports(module);
const expected = [{ module: "env", name: "zc_panic", kind: "function" }];
if (JSON.stringify(imports) !== JSON.stringify(expected)) {
  fail(`the module must import exactly ${JSON.stringify(expected)}, but imports ${JSON.stringify(imports)}`);
}

// ---- A host, as the page's is ---------------------------------------------------------------------

const decoder = new TextDecoder();
const encoder = new TextEncoder();

function start() {
  const host = { panic: null, exports: null };
  const instance = new WebAssembly.Instance(module, {
    env: {
      zc_panic(pointer, length) {
        host.panic = decoder.decode(new Uint8Array(host.exports.memory.buffer, pointer, length).slice());
      },
    },
  });
  host.exports = instance.exports;
  if (host.exports.zc_init() !== 0) fail("zc_init did not succeed");
  return host;
}

function request(host, method, path, query = "", body = "") {
  const e = host.exports;
  const frame = encoder.encode(`${method}\0${path}\0${query}\0\0${body}`);
  new Uint8Array(e.memory.buffer, e.zc_request_ptr(), frame.length).set(frame);
  const status = e.zc_request(frame.length);
  const text = decoder.decode(new Uint8Array(e.memory.buffer, e.zc_response_ptr(), e.zc_response_len()).slice());
  return { status, text, json: text ? JSON.parse(text) : null };
}

const OP = { reset: 0, step: 1, storeDown: 2, compact: 3, nextIndex: 6, stepsTotal: 7, isStoreDown: 8 };

function settle(host, seconds) {
  for (let i = 0; i < seconds; i++) host.exports.zc_advance(1000);
}

function expect(condition, message) {
  if (!condition) fail(message);
}

// ---- (2) Status, then the scenario -----------------------------------------------------------------

const host = start();
const status = request(host, "GET", "/v1/status");
expect(status.status === 200, `GET /v1/status answered ${status.status}`);
expect(status.json.store.ok === true, "the store is not ok");
expect(status.json.server.version === "0.0.0-sim", `unexpected server version ${status.json.server.version}`);
expect(status.json.time_ms === host.exports.zc_now_ms(), "status time_ms is not the world's clock");

const e = host.exports;
expect(e.zc_control(OP.stepsTotal, 0) === 7, "the scenario is not seven steps");
const wait = [3, 3, 3, 10, 3, 1, 3];
for (let i = 0; i < 7; i++) {
  expect(e.zc_control(OP.step, 0) === i, `step ${i} did not run as step ${i}`);
  expect(e.zc_control(OP.isStoreDown, 0) === (i === 5 ? 1 : 0), `store state wrong after step ${i}`);
  if (i === 5) {
    const down = request(host, "GET", "/v1/list", "prefix=%2Fservices%2F");
    expect(down.status === 503 && down.json.diagnostics[0].code === "ZC-E0201", "the store being down is not a 503 ZC-E0201");
    expect(e.zc_revision() === -1, "zc_revision should be -1 while the store is down");
  }
  settle(host, wait[i]);
}
expect(e.zc_control(OP.step, 0) === -1, "a finished scenario should have no more steps");

const hello = request(host, "GET", "/v1/why/service/hello");
expect(hello.json.state.text === "service hello: 2/2 running", `hello: ${hello.json.state.text}`);
const broken = request(host, "GET", "/v1/why/service/broken");
expect(broken.json.state.text === "service broken: 0/1 running", `broken: ${broken.json.state.text}`);
const last = broken.json.steps[broken.json.steps.length - 1];
expect(last.diagnostic?.code === "ZBX-E0501", "the chain for broken does not end in ZBX-E0501");

// A watch with nothing to report asks to be held, and a compaction makes an old bookmark a 410.
const head = e.zc_revision();
const held = request(host, "GET", "/v1/watch", `from=${head + 1}&timeout=5000`);
expect(held.status === 200 && e.zc_response_hold_ms() === 5000, "an idle watch should be held for its timeout");
e.zc_control(OP.compact, 0);
const gone = request(host, "GET", "/v1/watch", "from=2&timeout=0");
expect(gone.status === 410 && gone.json.diagnostics[0].code === "ZC-E0203", "a compacted watch should be 410 ZC-E0203");

const sent = encoder.encode("GET\0/v1/status\0\0my-own-id-1\0");
new Uint8Array(e.memory.buffer, e.zc_request_ptr(), sent.length).set(sent);
e.zc_request(sent.length);
const echoed = decoder.decode(new Uint8Array(e.memory.buffer, e.zc_response_id_ptr(), e.zc_response_id_len()).slice());
expect(echoed === "my-own-id-1", `the request id was not echoed: ${echoed}`);

// ---- (3) A panic goes through the one import, then traps -----------------------------------------------

const victim = start();
let trapped = null;
try {
  // A length past the request buffer breaks the doorway's own assertion.
  victim.exports.zc_request(0x7fffffff);
} catch (error) {
  trapped = error;
}
expect(trapped instanceof WebAssembly.RuntimeError, `a broken assertion should trap, got ${trapped}`);
expect(victim.panic && victim.panic.length > 0, "the trap came without a panic message through zc_panic");

console.log(`console check: ok (${bytes.length} bytes; one import, env.zc_panic; scenario, status, watch, 410 and a reported panic checked)`);
