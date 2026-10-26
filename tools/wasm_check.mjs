// Runs WebAssembly built from the control-plane core and checks the outcome.
//
//   node tools/wasm_check.mjs <zcube_core.wasm>          the freestanding library (zig build wasm-check)
//   node tools/wasm_check.mjs --wasi <core_tests.wasm>   the core's unit tests under WASI (zig build wasm-test)
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
const path = process.argv[wasi ? 3 : 2];
if (!path) {
  console.error("usage: node tools/wasm_check.mjs [--wasi] <module.wasm>");
  process.exit(2);
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
  const { instance } = await WebAssembly.instantiate(readFileSync(path), host.getImportObject());
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
console.log(`wasm check: ok (${rendered.length} bytes of rendered diagnostics)`);
