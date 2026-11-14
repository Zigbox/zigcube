// A dev-time browser check of the console, with Playwright and the Chromium that is already
// installed (never `playwright install`; no npm dependency is added to this repository).
//
//   node tools/browser_check.mjs <base-url> [--mode sim|server|mock] [--seed-hello] [--shots <dir>]
//
// sim:    opens <base>/?sim=c0, plays the C0 scenario through the panel at 8x and checks what the
//         real core, running as WebAssembly, tells: the `why service broken` chain, hello at 2/2,
//         the bug path (a forced panic shows a `bug` diagnostic with Reload), and phone width.
// server: opens <base>/ (a running zcube-server); with --seed-hello it first applies a 2-replica
//         hello through POST /v1/apply. Checks the page loads, the pill reaches Live, the service
//         shows and the why view renders.
// mock:   opens <base>/?mock=b1&at=3 (the JavaScript mock, B1's jobs, docs/console.md "Jobs"):
//         the list, the state filter, one job page per ending cause, the logs placeholder (and no
//         log request), and that no environment value or input text is on any page; then
//         ?mock=c3 (C3, a paused rollout): the service page's Rollout and Generations cards.
// All: no request leaves the origin, no page error, no console error.
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
if (!base || !["sim", "server", "mock"].includes(mode)) { console.error("usage: node tools/browser_check.mjs <base-url> [--mode sim|server|mock] [--seed-hello] [--shots <dir>]"); process.exit(2); }
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
  await check("sim: the real core answers rollout and history; the service page shows both cards", async () => {
    // C3 slice 11: no controller writes /rollouts/ yet (slice 7), so the rollout is null.
    const ro = await page.evaluate(() => window.zc.sim.request("GET", "/v1/services/hello/rollout"));
    must(ro.status === 200 && ro.body.rollout === null && ro.body.policy?.strategy === "rolling", `rollout: ${ro.status} ${JSON.stringify(ro.body).slice(0, 120)}`);
    const hist = await page.evaluate(() => window.zc.sim.request("GET", "/v1/services/hello/history"));
    must(hist.status === 200 && hist.body.generations?.length >= 1, `history: ${hist.status}`);
    const steer = await page.evaluate(() => window.zc.sim.request("POST", "/v1/services/hello/rollout/pause"));
    // The sim sends no body, which the API takes as no applied_by.
    must(steer.status === 409 && /ZC-E0129/.test(JSON.stringify(steer.body)), `pause with no rollout: ${steer.status}`);
    await page.evaluate(() => { location.hash = "#/services/hello"; });
    await page.waitForFunction(() => /No rollout/.test(document.querySelector("#h-ro")?.closest("section")?.innerText || "") && document.querySelectorAll("tr[data-generation]").length >= 1, null, { timeout: 15000 });
  });
  await check("sim: hello's replicas show the node they are assigned to", async () => {
    // Placement is /assigned/<node>/<id> (Replica v2 has no node): the replicas list joins on it.
    await page.evaluate(() => { location.hash = "#/replicas"; });
    await page.waitForFunction(() => document.querySelector("main")?.innerText.includes("hello-"), null, { timeout: 10000 });
    const rows = await page.$$eval("main tr", trs => trs.map(tr => tr.innerText).filter(t => t.includes("hello-")));
    must(rows.length > 0, "no hello replica rows");
    for (const row of rows) must(row.includes("node1") && !row.includes("unscheduled"), `row: ${row.replace(/\s+/g, " ")}`);
  });
  await check("sim: the why chain for broken comes from the real core", async () => {
    await page.evaluate(() => { location.hash = "#/why/service/broken"; });
    await page.waitForFunction(() => document.querySelector("main")?.innerText.includes("ZBX-E0410"), null, { timeout: 10000 });
    const text = await page.innerText("main");
    must(text.includes("service broken: 0/1 running"), "headline missing");
    must(text.includes("hold_failed_replica") || /not replaced/.test(text), "the hold sentence is missing");
    must(await page.locator('article.diag a.code:text-is("ZBX-E0410")').count() > 0, "no ZBX-E0410 diagnostic block");
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
} else if (mode === "mock") {
  const logRequests = [];
  const page = await open({ width: 1280, height: 900 }, `${base}/?mock=b1&at=3#/jobs`);
  page.on("request", r => { if (/log/i.test(new URL(r.url()).pathname)) logRequests.push(r.url()); });
  const text = () => page.evaluate(() => document.querySelector("main")?.innerText || "");
  const rowsWith = () => page.$$eval("tr[data-job]", trs => trs.map(t => [t.dataset.job, t.dataset.state, t.dataset.end]));
  await check("mock: the list shows all eighteen jobs", async () => {
    await page.waitForFunction(() => document.querySelectorAll("tr[data-job]").length === 18, null, { timeout: 15000 });
    await shot(page, "mock-jobs");
  });
  await check("mock: the state filter narrows the list", async () => {
    await page.selectOption("main select", "running");
    await page.waitForFunction(() => document.querySelectorAll("tr[data-job]").length === 1, null, { timeout: 15000 });
    await page.selectOption("main select", "ended");
    await page.waitForFunction(() => document.querySelectorAll("tr[data-job]").length === 15, null, { timeout: 15000 });
    await page.selectOption("main select", "");
  });
  // Every ending the controller can record (src/job_controller.zig `map_ending`, `end_unstarted`):
  // [state, the Ended-with word on the row, the page's Ended line, the stop cause or null, a decision the chain must name].
  const ends = {
    "train-ok": ["exited", "exit 0", "exited with code 0", null],
    "export-exit3": ["exited", "exit 3", "exited with code 3", null],
    "probe-sigkill": ["exited", "signal 9", "exited: killed by signal 9", null],
    "fit-oom": ["failed", "oom", "failed: ran out of memory", null],
    "fork-bomb": ["failed", "pid_limit", "failed: hit its process limit", null],
    "bad-image": ["failed", "start_failed", "failed: could not be started", null],
    "slow-merge": ["failed", "deadline", "failed: passed its deadline", "deadline"],
    "fenced-write": ["failed", "fenced", "failed: was stopped", "fence"],
    "lost-node": ["failed", "unreachable", "failed: its node stopped being heard", "unreachable"],
    "never-started": ["failed", "deadline", "failed: passed its deadline", "not_started", "end_job"], // placed, never claimed: end_job cites the desired run (no stop_job link)
    "lost-early": ["failed", "not_started", "failed: its node was lost before the run was claimed", "unreachable", "end_job"],
    "mystery": ["failed", "unknown", "failed: ended for a reason", null],
    "no-room": ["failed", "deadline", "failed: passed its deadline", "not_started", "end_job"], // held, then the backstop
    "cancel-running": ["cancelled", "cancelled", "cancelled", "cancel"],
    "cancel-waiting": ["cancelled", "cancelled", "cancelled", "cancel", "end_job"], // cancelled before placement
    "run-forever": ["running", "", null, null],
    "placed-wait": ["placed", "", null, null, "job_placed"],
    "waiting": ["pending", "", null, null, "hold_pending"], // the no-room hold
  };
  await check("mock: the list rows show each job's state and ending", async () => {
    await page.waitForFunction(() => document.querySelectorAll("tr[data-job]").length === 18, null, { timeout: 15000 });
    const rows = Object.fromEntries((await rowsWith()).map(([n, st, en]) => [n, [st, en]]));
    for (const [name, [state, word]] of Object.entries(ends)) must(rows[name] && rows[name][0] === state && rows[name][1] === word, `${name}: row is ${JSON.stringify(rows[name])}, want ${state} / "${word}"`);
  });
  for (const [name, [state, word, longText, stop, decision]] of Object.entries(ends)) {
    await check(`mock: job page ${name} (${state} ${word})`, async () => {
      await page.evaluate(n => { location.hash = `#/jobs/${n}`; }, name);
      await page.waitForFunction(n => document.querySelector("main h1")?.textContent === n && /Spec/.test(document.querySelector("main")?.innerText || ""), name, { timeout: 15000 });
      await page.waitForFunction(() => !/Loading…/.test(document.querySelector("main")?.innerText || ""), null, { timeout: 15000 });
      const t = await text();
      must(t.includes("Logs are not part of this release"), "no logs placeholder");
      must(!t.includes("s3cr3t-token") && !t.includes("epochs=3"), "an env value or the input is on the page");
      must(!/\bnull\b|undefined/.test(t), "null or undefined on the page");
      must(new RegExp(`State\\s+\\S*\\s*${state}\\b`, "i").test(t), `the page does not say the state is ${state}`);
      if (longText) must(new RegExp(`Ended\\s+${longText.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`).test(t), `the Ended line is not "${longText}"`);
      else must(!/\bEnded\s/.test(t), "an unended job shows an Ended line");
      if (stop) must(new RegExp(`Stopped because\\s+${stop}\\b`).test(t), `the stop cause is not ${stop}`);
      else must(!/Stopped because/.test(t), "a stop cause on a job that had none");
      must(t.includes("Why") && /because/i.test(t), "no why chain");
      if (decision) must(t.includes(decision), `the chain does not name ${decision}`);
      if (decision === "end_job") must(!t.includes("stop_job"), "an unclaimed run's end cites the desired run: stop_job is not a link of its chain");
      if (name === "bad-image") must(/ZBX-E0410/.test(t), "no diagnostic");
      if (name === "train-ok") await shot(page, "mock-job-train-ok");
    });
  }
  await check("mock: an unknown job is a diagnostic with its code", async () => {
    await page.evaluate(() => { location.hash = "#/jobs/nope"; });
    await page.waitForFunction(() => /ZC-E0133/.test(document.querySelector("main")?.innerText || ""), null, { timeout: 15000 });
  });
  await check("mock: why job renders its chain", async () => {
    await page.evaluate(() => { location.hash = "#/why/job/fit-oom"; });
    await page.waitForFunction(() => /job fit-oom/.test(document.querySelector("main")?.innerText || ""), null, { timeout: 15000 });
  });
  await check("mock: no log request was made", async () => { must(!logRequests.length, logRequests.join(", ")); });
  await page.context().close();
  // C3 slice 11: the service page's Rollout and Generations cards over ?mock=c3 (a paused rollout).
  for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 800 }]) {
    const c3 = await open(viewport, `${base}/?mock=c3&at=4#/services/hello`);
    const card = id => c3.$eval(id, el => el.closest("section").innerText);
    await check(`mock c3 ${viewport.width}px: the rollout card shows the paused rollout`, async () => {
      await c3.waitForFunction(() => /paused/.test(document.querySelector("#h-ro")?.closest("section")?.innerText || ""), null, { timeout: 15000 });
      const t = await card("#h-ro");
      must(/1 → 2/.test(t), "no 1 → 2");
      must(/by user/.test(t), "no paused by user");
      must(/zcube rollout resume hello/.test(t), "no resume command");
      must(/on failure rollback/.test(t), "no policy");
      must(!/\bnull\b|undefined|NaN/.test(t), "null, undefined or NaN on the card");
    });
    await check(`mock c3 ${viewport.width}px: the generations card lists both, newest first`, async () => {
      await c3.waitForFunction(() => document.querySelectorAll("tr[data-generation]").length === 2, null, { timeout: 15000 });
      const gens = await c3.$$eval("tr[data-generation]", trs => trs.map(t => t.dataset.generation));
      must(gens.join(",") === "2,1", `generations ${gens}`);
      const t = await card("#h-gen");
      must(/now/.test(t) && /apply/.test(t), "no current mark or reason");
      must(!/\bnull\b|undefined|NaN/.test(t), "null, undefined or NaN on the card");
      must(!(await c3.content()).includes("s3cr3t-c3"), "an env value is on the page");
      await shot(c3, `mock-c3-${viewport.width}`);
    });
    await c3.context().close();
  }
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
