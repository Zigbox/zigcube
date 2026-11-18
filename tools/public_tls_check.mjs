// C5 slice 1's browser check (docs/briefs/c5.md; docs/mtls.md, "The public path"): real Chromium
// completes a TLS 1.3 handshake with the server's public path. Uses the Chromium that is already
// installed (never `playwright install`; no npm dependency) and NSS's `certutil`.
//
//   node tools/public_tls_check.mjs LISTENER
//
// LISTENER is `zig-out`'s `public_tls_listener` (`zig build public-tls-check` passes it). It writes
// its test CA, serves https://hello.test:PORT/ on 127.0.0.1, and answers one request per
// connection. Two runs of Chromium, each with a scratch HOME (its NSS store):
//   1. with an empty store, the page must fail with ERR_CERT_AUTHORITY_INVALID (the test CA is not
//      trusted anywhere else, so a pass in step 2 is the store's doing);
//   2. with the test CA imported as trusted, the page must load: status 200 and the listener's
//      body naming host=hello.test and alpn=http/1.1.
// Prints `public-tls-check: PASS chromium <version>` or a reason and exits 1; 60 s at most.

import { createRequire } from "node:module";
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const { chromium } = createRequire(import.meta.url)("playwright");

const listener_path = process.argv[2];
if (!listener_path) {
  console.error("usage: node tools/public_tls_check.mjs LISTENER");
  process.exit(2);
}
const scratch = mkdtempSync(join(tmpdir(), "zcube-public-tls-"));
let listener = null;
function fail(reason) {
  console.error(`public-tls-check: FAIL ${reason}`);
  if (listener) listener.kill("SIGKILL");
  rmSync(scratch, { recursive: true, force: true });
  process.exit(1);
}
setTimeout(() => fail("no result in 60 s"), 60000).unref();

const ca_path = join(scratch, "ca.der");
const port = await new Promise((resolve, reject) => {
  listener = spawn(listener_path, ["--ca-out", ca_path], { stdio: ["ignore", "ignore", "pipe"] });
  let text = "";
  listener.stderr.on("data", chunk => {
    text += chunk;
    process.stderr.write(chunk);
    const match = /listening (\d+)/.exec(text);
    if (match) resolve(Number(match[1]));
  });
  listener.on("exit", code => reject(new Error(`listener exited ${code}`)));
}).catch(e => fail(e.message));

// A scratch HOME whose NSS store holds the test CA, as trusted for servers, or nothing.
function home(name, trust) {
  const dir = join(scratch, name);
  const db = join(dir, ".pki", "nssdb");
  mkdirSync(db, { recursive: true });
  execFileSync("certutil", ["-N", "-d", `sql:${db}`, "--empty-password"]);
  if (trust) {
    execFileSync("certutil", ["-A", "-d", `sql:${db}`, "-n", "zcube public test CA", "-t", "C,,",
      "-i", ca_path]);
  }
  return dir;
}

// One Chromium run with `dir` as HOME: the response, or the navigation error's message.
async function visit(dir) {
  // The container's proxy variables would send hello.test to the egress proxy, not the listener.
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/proxy/i.test(k)));
  env.HOME = dir;
  const browser = await chromium.launch({
    env,
    args: ["--host-resolver-rules=MAP hello.test 127.0.0.1", "--no-proxy-server"],
  });
  try {
    const page = await browser.newPage();
    const response = await page.goto(`https://hello.test:${port}/`).catch(e => e);
    if (response instanceof Error) return { error: response.message, version: browser.version() };
    return { status: response.status(), body: await response.text(), version: browser.version() };
  } finally {
    await browser.close();
  }
}

const untrusted = await visit(home("untrusted", false));
if (!untrusted.error || !untrusted.error.includes("ERR_CERT_AUTHORITY_INVALID")) {
  fail(`without the test CA: expected ERR_CERT_AUTHORITY_INVALID, got ` +
    (untrusted.error ? untrusted.error.split("\n")[0] : `status ${untrusted.status}`));
}
const trusted = await visit(home("trusted", true));
if (trusted.error) fail(`with the test CA: ${trusted.error.split("\n")[0]}`);
if (trusted.status !== 200) fail(`with the test CA: status ${trusted.status}`);
if (!trusted.body.includes("host=hello.test") || !trusted.body.includes("alpn=http/1.1")) {
  fail(`with the test CA: body ${JSON.stringify(trusted.body)}`);
}
listener.kill("SIGKILL");
rmSync(scratch, { recursive: true, force: true });
console.log(`public-tls-check: PASS chromium ${trusted.version}`);
process.exit(0);
