// A dev-time browser check of the console, with Playwright and the Chromium that is already
// installed (never `playwright install`; no npm dependency is added to this repository).
//
//   node tools/browser_check.mjs <base-url> [--mode sim|server] [--seed-hello] [--shots <dir>]
//
// sim:    opens <base>/?sim=c0, plays the C0 scenario through the panel at 8x and checks what the
//         real core, running as WebAssembly, tells: the `why service broken` chain, hello at 2/2,
//         the bug path (a forced panic shows a `bug` diagnostic with Reload), and phone width.
// server: opens <base>/ (a running zcube-server); with --seed-hello it first applies a 2-replica
//         hello through POST /v1/apply. Checks the page loads, the pill reaches Live, the service
//         shows and the why view renders.
// Both: no request leaves the origin, no page error, no console error.
// Prints one PASS/FAIL line per check and exits non-zero if any failed.

import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
const { chromium } = createRequire(import.meta.url)("playwright");

const args = process.argv.slice(2);
const base = (args.find(a => /^https?:/.test(a)) || "").replace(/\/$/, "");
const flag = name => args.includes(name);
const option = name => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const mode = option("--mode") || "sim";
const shots = option("--shots");
if (!base || !["sim", "server"].includes(mode)) { console.error("usage: node tools/browser_check.mjs <base-url> [--mode sim|server] [--seed-hello] [--shots <dir>]"); process.exit(2); }
if (shots) mkdirSync(shots, { recursive: true });

let failures = 0;
async function check(name, fn) {
  try { await fn(); console.log(`PASS ${name}`); } catch (e) { failures++; console.log(`FAIL ${name}: ${String(e.message || e).split("\n")[0]}`); }
}
const must = (cond, message) => { if (!cond) throw new Error(message); };
const origin = new URL(base).origin;

const browser = await chromium.launch();
const observed = { external: [], errors: [] };
async function open(viewport, url) {
  const context = await browser.newContext({ viewport });
  const page = await context.newPage();
  page.on("request", r => {
    const u = r.url();
    if (u.startsWith("data:image/svg+xml")) return; // the inline favicon
    if (new URL(u).origin !== origin) observed.external.push(u);
  });
  page.on("pageerror", e => observed.errors.push(`pageerror: ${e.message}`));
  page.on("console", m => { if (m.type() === "error") observed.errors.push(`console.error: ${m.text()}`); });
  await page.goto(url);
  try { await page.waitForSelector('#conn[data-conn="live"]', { timeout: 20000 }); } catch {
    failures++; console.log(`FAIL ${url}: the connection pill never reached Live`);
  }
  return page;
}
const shot = (page, name) => shots && page.screenshot({ path: `${shots}/${name}.png`, fullPage: true });

if (mode === "sim") {
  const page = await open({ width: 1280, height: 900 }, `${base}/?sim=c0`);
  await check("sim: the environment tag says simulated", async () => {
    must((await page.textContent("#env-tag")) === "simulated", "env tag is not 'simulated'");
  });
  await check("sim: playing the scenario to the end at 8x", async () => {
    await page.click(".dev-bar");
    await page.selectOption("#dev-speed", "8");
    await page.click('.dev button:text-is("Play")');
    await page.waitForFunction(() => document.querySelector(".dev-bar [role=status]")?.textContent === "done", null, { timeout: 90000 });
  });
  await check("sim: hello is 2/2 running and shown on the overview", async () => {
    await page.evaluate(() => { location.hash = "#/"; });
    await page.waitForFunction(() => document.querySelector("main")?.innerText.includes("hello"), null, { timeout: 10000 });
    const why = await page.evaluate(() => window.zc.sim.request("GET", "/v1/why/service/hello"));
    must(why.body.state.text === "service hello: 2/2 running", `state: ${why.body.state.text}`);
    await shot(page, "sim-overview");
  });
  await check("sim: the why chain for broken comes from the real core", async () => {
    await page.evaluate(() => { location.hash = "#/why/service/broken"; });
    await page.waitForFunction(() => document.querySelector("main")?.innerText.includes("ZBX-E0501"), null, { timeout: 10000 });
    const text = await page.innerText("main");
    must(text.includes("service broken: 0/1 running"), "headline missing");
    must(text.includes("hold_failed_replica") || /not replaced/.test(text), "the hold sentence is missing");
    must(await page.locator('article.diag a.code:text-is("ZBX-E0501")').count() > 0, "no ZBX-E0501 diagnostic block");
    await shot(page, "sim-why-broken");
  });
  await check("sim: a forced panic shows a bug diagnostic with Reload, and the page stays up", async () => {
    const before = observed.errors.length;
    await page.evaluate(() => window.zc.sim.forcePanic());
    await page.waitForSelector('#banner article.diag[data-severity="bug"]', { timeout: 15000 });
    await page.waitForSelector("#reload");
    must((await page.innerText("#banner")).includes("ZC-B0001"), "no ZC-B0001");
    must(observed.errors.length === before || observed.errors.slice(before).every(e => !e.startsWith("pageerror")), "a page error followed the panic");
    await shot(page, "sim-bug");
  });
  await page.context().close();
  const phone = await open({ width: 390, height: 800 }, `${base}/?sim=c0`);
  await phone.waitForTimeout(500);
  for (const route of ["#/", "#/services", "#/replicas", "#/why/service/hello"]) {
    await check(`phone width: ${route} has no horizontal page scroll`, async () => {
      await phone.evaluate(r => { location.hash = r; }, route);
      await phone.waitForTimeout(400);
      const [scroll, width] = await phone.evaluate(() => [document.documentElement.scrollWidth, innerWidth]);
      must(scroll <= width, `scrollWidth ${scroll} > ${width}`);
      must(await phone.locator("nav.side").isVisible(), "the tab row is not visible");
      await shot(phone, `sim-phone-${route.replace(/\W+/g, "-")}`);
    });
  }
  await phone.context().close();
} else {
  if (flag("--seed-hello")) {
    const body = { name: "hello", image: "b3:51aa9c03", replicas: 2, command: ["sh", "-c", "while true; do sleep 1; done"], applied_by: "browser-check" };
    const r = await fetch(`${base}/v1/apply`, { method: "POST", body: JSON.stringify(body) });
    if (!r.ok) { console.log(`FAIL seed: POST /v1/apply answered ${r.status}`); failures++; }
  }
  const page = await open({ width: 1280, height: 900 }, `${base}/`);
  await check("server: the page title and the environment tag", async () => {
    const served = await (await fetch(`${base}/`)).text(); // the router retitles the page, so read what the server sent
    must(/<title>Zigcube console<\/title>/.test(served), "GET / is not the console page");
    must((await page.title()).includes("Zigcube"), `title is ${await page.title()}`);
    must((await page.textContent("#env-tag")) === "server", "env tag is not 'server'");
  });
  await check("server: the connection pill is Live", async () => {
    must(/Live/.test(await page.textContent("#conn")), "not live");
  });
  await check("server: the applied service shows and its why view renders", async () => {
    await page.evaluate(() => { location.hash = "#/services"; });
    await page.waitForFunction(() => document.querySelector("main")?.innerText.includes("hello"), null, { timeout: 15000 });
    await page.evaluate(() => { location.hash = "#/why/service/hello"; });
    await page.waitForFunction(() => /service hello/.test(document.querySelector("main")?.innerText || ""), null, { timeout: 15000 });
    await shot(page, "server-why-hello");
  });
  await page.context().close();
  const phone = await open({ width: 390, height: 800 }, `${base}/`);
  for (const route of ["#/", "#/services", "#/replicas"]) {
    await check(`phone width: ${route} has no horizontal page scroll`, async () => {
      await phone.evaluate(r => { location.hash = r; }, route);
      await phone.waitForTimeout(400);
      const [scroll, width] = await phone.evaluate(() => [document.documentElement.scrollWidth, innerWidth]);
      must(scroll <= width, `scrollWidth ${scroll} > ${width}`);
    });
  }
  await phone.context().close();
}

await check("no request left the origin", async () => { must(!observed.external.length, observed.external.join(", ")); });
await check("no page errors and no console errors", async () => { must(!observed.errors.length, `${observed.errors.length}: ${[...new Set(observed.errors)].slice(0, 3).join(" | ")}`); });
await browser.close();
process.exit(failures ? 1 : 0);
