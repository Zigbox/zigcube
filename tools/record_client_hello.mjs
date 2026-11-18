// Records the first TLS handshake message a real browser sends (its ClientHello), as raw record
// bytes, for the public TLS mode's fixtures (docs/briefs/c5.md, slice 1; src/testdata/tls/README.md).
// Uses the Chromium that is already installed (never `playwright install`; no npm dependency).
//
//   node tools/record_client_hello.mjs --out FILE
//
// A raw TCP listener on 127.0.0.1 takes the browser's first connection to https://hello.test:PORT/,
// reads records until the first handshake message is complete, writes those bytes and closes.
// Prints `recorded chromium <version> <N> bytes -> FILE`; exits 1 after 30 s without one.

import { createRequire } from "node:module";
import { createServer } from "node:net";
import { writeFileSync } from "node:fs";
const { chromium } = createRequire(import.meta.url)("playwright");

const args = process.argv.slice(2);
const at = args.indexOf("--out");
const out = at >= 0 ? args[at + 1] : null;
if (!out) { console.error("usage: node tools/record_client_hello.mjs --out FILE"); process.exit(2); }
setTimeout(() => { console.error("record_client_hello: no ClientHello in 30 s"); process.exit(1); }, 30000).unref();

// The length of the complete records in `bytes` that hold the first handshake message, or 0.
function complete(bytes) {
  let at = 0;
  const body = [];
  while (at + 5 <= bytes.length) {
    if (bytes[at] !== 0x16) throw new Error(`record type ${bytes[at]}, not handshake`);
    const length = bytes.readUInt16BE(at + 3);
    if (at + 5 + length > bytes.length) return 0;
    body.push(bytes.subarray(at + 5, at + 5 + length));
    at += 5 + length;
    const joined = Buffer.concat(body);
    if (joined.length >= 4 && joined.length >= 4 + joined.readUIntBE(1, 3)) return at;
  }
  return 0;
}

const recorded = new Promise((resolve, reject) => {
  const server = createServer(socket => {
    let bytes = Buffer.alloc(0);
    socket.on("data", chunk => {
      bytes = Buffer.concat([bytes, chunk]);
      try {
        const length = complete(bytes);
        if (length === 0) return;
        writeFileSync(out, bytes.subarray(0, length));
        socket.destroy();
        server.close();
        resolve(length);
      } catch (e) { reject(e); }
    });
    socket.on("error", () => {});
  });
  server.listen(0, "127.0.0.1", () => launch(server.address().port).catch(reject));
});

let browser = null;
async function launch(port) {
  // The container's proxy variables would send hello.test to the egress proxy, not the listener.
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/proxy/i.test(k)));
  const options = { env, args: ["--host-resolver-rules=MAP hello.test 127.0.0.1", "--no-proxy-server"] };
  browser = await chromium.launch(options);
  const page = await browser.newPage();
  await page.goto(`https://hello.test:${port}/`).catch(() => {});
}

const length = await recorded;
const version = browser ? browser.version() : "unknown";
if (browser) await browser.close();
console.log(`recorded chromium ${version} ${length} bytes -> ${out}`);
process.exit(0);
