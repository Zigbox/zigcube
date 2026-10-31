// Runs WebAssembly built from the control-plane core and checks the outcome.
//
//   node tools/wasm_check.mjs <zcube_core.wasm>          the freestanding library (zig build wasm-check)
//   node tools/wasm_check.mjs --wasi <core_tests.wasm>   the core's unit tests under WASI (zig build wasm-test)
//   node tools/wasm_check.mjs --sim <zcube_core.wasm> <seed> <operations> <native scenario> <native fuzz>
//                                                        the C0 simulation, compared with the native run (zig build sim-c0)
//   node tools/wasm_check.mjs --sim-cluster <zcube_core.wasm> <seed> <operations> <nodes> <liveness> <native report>
//                                                        the cluster simulation, compared with the native run (zig build sim-cluster)
//
// Why JavaScript, when docs/STYLE.md prefers Zig tooling: the check must execute a WebAssembly
// module, and neither Zig's standard library nor the CI image has a WebAssembly runtime (no
// wasmtime, no wasmer). Node has one built in, is on every GitHub runner, and runs the same engine
// as the browsers the core is meant for. Everything else (building, deciding what to run) is Zig:
// this file instantiates a module, calls one export or starts it, and compares text. It imports
// only Node's own modules, installs nothing, and holds no logic of the core.

import { closeSync, mkdtempSync, openSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const wasi = process.argv[2] === "--wasi";
const sim = process.argv[2] === "--sim";
const simCluster = process.argv[2] === "--sim-cluster";
const path = process.argv[wasi || sim || simCluster ? 3 : 2];
if (!path) {
  console.error("usage: node tools/wasm_check.mjs [--wasi | --sim ...] <module.wasm>");
  process.exit(2);
}

// A fresh instance per run: a trap poisons an instance (docs/wasm.md), so runs must not share one.
async function instantiate(bytes) {
  const { instance } = await WebAssembly.instantiate(bytes, {});
  return instance.exports;
}

function simReport(exports) {
  const rendered = new Uint8Array(exports.memory.buffer, exports.zcube_sim_report_ptr(), exports.zcube_sim_report_len());
  return new TextDecoder().decode(rendered);
}

function firstDifference(left, right) {
  const a = left.split("\n");
  const b = right.split("\n");
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) return `line ${i + 1}:\n  native: ${a[i]}\n  wasm:   ${b[i]}`;
  }
  return "(no difference found)";
}

if (simCluster) {
  // Same contract as --sim: the native report arrives as a file; the two must be equal byte for byte.
  const [wasmPath, seedText, operationsText, nodesText, livenessText, nativePath] = process.argv.slice(3);
  const exports = await instantiate(readFileSync(wasmPath));
  const started = Date.now();
  const failed = exports.zcube_sim_cluster(BigInt(seedText), Number(operationsText), Number(nodesText), livenessText === "true" ? 1 : 0);
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  const rendered = new Uint8Array(exports.memory.buffer, exports.zcube_cluster_report_ptr(), exports.zcube_cluster_report_len());
  const wasmText = new TextDecoder().decode(rendered);
  const nativeText = readFileSync(nativePath, "utf8");
  if (failed !== 0 || wasmText !== nativeText) {
    console.error(`sim-cluster (seed ${seedText}): wasm ${failed === 0 ? "held every check" : "failed"}; reports ${wasmText === nativeText ? "agree" : "differ"}`);
    if (wasmText !== nativeText) console.error(firstDifference(nativeText, wasmText));
    console.error(wasmText);
    process.exit(1);
  }
  console.log(`sim-cluster: seed ${seedText}: native and wasm agree byte for byte (${wasmText.length} bytes; ${operationsText} operations, nodes ${nodesText === "0" ? "by seed" : nodesText}, liveness ${livenessText}; wasm ${seconds} s)`);
  process.exit(0);
}

if (sim) {
  // The simulation is deterministic: the same seed must give the same report, byte for byte, in
  // WebAssembly and natively. The native reports arrive as files, written by the native run.
  const [wasmPath, seedText, operationsText, nativeScenario, nativeFuzz] = process.argv.slice(3);
  const bytes = readFileSync(wasmPath);
  const seed = BigInt(seedText);
  const operations = Number(operationsText);
  const cases = [
    ["scenario", (e) => e.zcube_sim_c0(seed), nativeScenario],
    ["fuzz", (e) => e.zcube_sim_fuzz(seed, operations), nativeFuzz],
  ];
  const sizes = [];
  for (const [name, run, nativePath] of cases) {
    const exports = await instantiate(bytes);
    const failed = run(exports);
    const wasmText = simReport(exports);
    const nativeText = readFileSync(nativePath, "utf8");
    if (failed !== 0 || wasmText !== nativeText) {
      console.error(`sim-c0 ${name} (seed ${seedText}): wasm stopped at step ${failed}; reports ${wasmText === nativeText ? "agree" : "differ"}`);
      if (wasmText !== nativeText) console.error(firstDifference(nativeText, wasmText));
      console.error(wasmText);
      process.exit(1);
    }
    sizes.push(`${name} ${wasmText.length} bytes`);
  }
  console.log(`sim-c0: seed ${seedText}: native and wasm agree byte for byte (${sizes.join(", ")}; fuzz ${operations} operations)`);
  process.exit(0);
}

if (wasi) {
  // The test binary is a WASI command: it runs the tests when started and exits non-zero if one
  // fails. Its progress goes to stderr, which the build runner would count as a failure of a
  // passing step, so it goes to a file instead and is shown only when the tests fail.
  const { WASI } = await import("node:wasi");
  const directory = mkdtempSync(join(tmpdir(), "zcube-wasm-test-"));
  const log = join(directory, "stderr.log");
  const logFd = openSync(log, "w");
  const host = new WASI({
    version: "preview1",
    args: ["core_tests"],
    env: {},
    returnOnExit: true,
    stderr: logFd,
  });
  // Every WASI import goes through a JavaScript function. Node's native import, called straight
  // from wasm, allocates in `uvwasi_fd_write`, which reports external memory to V8; with the
  // test heap grown past ~130 MiB that starts a full GC *inside* the call, and V8 (Node 22.23)
  // dies in SIGSEGV walking the wasm frame (`IterateTurbofanOptimizedFrame`), under both
  // compilers and with no trap. A JavaScript import has a frame V8 can walk.
  const imports = host.getImportObject();
  const preview1 = imports.wasi_snapshot_preview1;
  for (const [name, native] of Object.entries(preview1)) preview1[name] = (...args) => native(...args);
  const { instance } = await WebAssembly.instantiate(readFileSync(path), imports);
  const code = host.start(instance);
  closeSync(logFd);
  const output = readFileSync(log, "utf8");
  rmSync(directory, { recursive: true });
  if (code !== 0) {
    console.error(output);
    console.error(`wasm test failed: the core's tests exited with ${code}`);
    process.exit(1);
  }
  const passed = output.match(/All (\d+) tests passed/);
  console.log(`wasm test: ok (${passed ? passed[1] : "all"} unit tests of the core passed under WASI)`);
  process.exit(0);
}

const bytes = readFileSync(path);
const imports = WebAssembly.Module.imports(new WebAssembly.Module(bytes));
// The module needs nothing from the host: an import here would mean the core reached for a
// service (a clock, a file, a socket) that the shell must provide, and that is a finding.
if (imports.length !== 0) {
  console.error("wasm check failed: the core imports from its host:", JSON.stringify(imports));
  process.exit(1);
}

const { instance } = await WebAssembly.instantiate(bytes, {});
const exports = instance.exports;
const failed = exports.zcube_smoke();
const rendered = new Uint8Array(exports.memory.buffer, exports.zcube_report_ptr(), exports.zcube_report_len());
const report = new TextDecoder().decode(rendered);

const expected = [
  "error[ZC-E0203]:",
  "zcube explain E0203",
  "https://zigbox.github.io/zigcube/errors/E0203.html",
  "error[ZBX-E0501]: image not found",
  "zbx explain E0501",
  "https://zigbox.github.io/zigbox/errors/E0501.html",
];
const missing = expected.filter((line) => !report.includes(line));

if (failed !== 0 || missing.length > 0) {
  console.error(`wasm check failed: scenario stopped at step ${failed}; missing in report:`, missing);
  console.error(report);
  process.exit(1);
}

// The C0 simulation, run in the module: the scenario for a few seeds, and the fuzz variant. Each
// returns the step it stopped at (0: every step held) and a report to read.
const simSeeds = [1n, 2n, 3n, 0xdeadbeefn];
const fuzzSeeds = [1000n, 1001n];
const fuzzOperations = 40;
const simProblems = [];
let simBytes = 0;
for (const seed of simSeeds) {
  const sim = await instantiate(bytes);
  const stopped = sim.zcube_sim_c0(seed);
  const text = simReport(sim);
  simBytes += text.length;
  const expectedText = ["sim-c0: every step held", "error[ZBX-E0501]: image not found", "service broken: 0/1 running"];
  const absent = expectedText.filter((line) => !text.includes(line));
  if (stopped !== 0 || absent.length > 0) simProblems.push(`scenario seed ${seed}: stopped at step ${stopped}, missing ${JSON.stringify(absent)}\n${text}`);
}
for (const seed of fuzzSeeds) {
  const sim = await instantiate(bytes);
  const stopped = sim.zcube_sim_fuzz(seed, fuzzOperations);
  const text = simReport(sim);
  simBytes += text.length;
  if (stopped !== 0 || !text.includes("fuzz: every invariant held")) simProblems.push(`fuzz seed ${seed}: stopped at step ${stopped}\n${text}`);
}
if (simProblems.length > 0) {
  console.error("wasm check failed: the C0 simulation did not hold in the module:");
  for (const problem of simProblems) console.error(problem);
  process.exit(1);
}
console.log(`wasm check: ok (${rendered.length} bytes of rendered diagnostics; the C0 simulation held for ${simSeeds.length} seeds and ${fuzzSeeds.length} fuzz runs, ${simBytes} bytes of report)`);
