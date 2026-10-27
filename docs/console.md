# The Zigcube web console

Design of the console. Status (C0 slice 5b): **it runs in three modes**, all through the same
client and model, and the first two are the product:

| Mode | How | What answers `/v1` |
| --- | --- | --- |
| **Live server** | open the page `zcube-server` serves at `/` (or `/console/`) | the real server, on the same origin |
| **Simulation** | `?sim=c0` | the **real control-plane core compiled to WebAssembly**, in the browser, over a memory store and the simulated runtime, on virtual time (`web/sim/`, `src/console_wasm.zig`) |
| **Mock** | `?mock=c1` | a JavaScript model of the proposed API (`web/mock/`). It remains only for **C1** (several nodes, failover), because the core has no C1 yet; the UI says "mock" |

The simulation is labelled **simulated** in the header and the panel. It is a simulation: nothing
in it is recorded, no process starts, and it is never presented as a demo that passed (`demo-c0`
is a different thing and is slice 6). `?mock=c0` links still work: they open `?sim=c0`.

## What it is, and what was decided

- A **web console served by `zcube-server` itself**, embedded with `@embedFile`, so one static
  binary ships everything (the simulation's WebAssembly module included). Files live in `web/`.
- **No build step.** Plain HTML, CSS and ES modules. No npm, no bundler, no framework.
- **No external requests at runtime**, so it works on an air-gapped cluster: no CDN, no web
  fonts, no analytics. It uses the system font stack. The project site uses Familjen Grotesk and
  IBM Plex from Google Fonts; those are not vendored, because a console that renders in the
  platform's own fonts is faster and loses nothing a dense working tool needs. If the owner wants
  the brand fonts here, the files go under `web/fonts/` with a licence note.
- **Read-only.** Changes go through `zcube apply` and git. Wherever a user would want to change
  something, the console shows the exact command (see [Interaction rules](#interaction-rules)).
- **One client, three transports.** `web/js/api.js` talks through a transport with the shape of
  `fetch`: the browser's (`fetchTransport`, the default), the simulation's (`web/sim/index.js`) or
  the mock's. Nothing above the transport knows which one it has.

The look continues `site/index.html`: the same palette, the same terminal blocks, the diamond
mark. The landing page is generous and editorial; the console is dense and calm. Colour is
reserved for state, and every state also has a glyph and a word.

## Information architecture

Seven screens, one sentence each. Deep links are hash routes, so they work from a static file.

| Screen | URL | Answers |
| --- | --- | --- |
| Overview | `#/` | Is the fleet healthy, and if not, where do I click? |
| Services | `#/services` | What is declared, and is each service doing what it was asked? |
| Service | `#/services/<name>` | Spec, replicas, decision history for one service |
| Replicas | `#/replicas` | Every replica: node, digest, status, exit reason |
| Nodes | `#/nodes`, `#/nodes/<name>` | Capacity declared vs used, lease state, what runs there |
| Why | `#/why/<service\|replica\|node>/<name>[?decision=<id>]`, `#/why` | The causal chain behind a state |
| Decisions | `#/decisions` | Everything the controllers did, with causes |
| Codes | `#/codes`, `#/codes/<code>` | `zcube explain`, in the browser |

Navigation is a left rail on desktop and a horizontally scrolling tab row on a phone. There is no
hamburger menu: seven items fit in a scrolling row, and a menu would hide the thing a person
reaches for first. Keyboard: `g` then `o s r n d w c` jumps between screens, `/` focuses the
filter, `?` lists them.

**Every object links to its Why view.** A service, replica or node name in a table goes to its
detail or its Why; every row also ends in a `why` link; every item in "Needs attention" is one
click from its explanation. Decisions link to the chain as of that decision.

There is deliberately no replica detail screen. A replica's whole story is its Why chain plus
its records, shown beside the chain.

## Screens

### Overview

A one-sentence summary at the top ("1 of 2 services healthy · 2 of 3 replicas running · 1 of 1
node ready"), then two columns.

- **Needs attention** (fixed height, so it never pushes the page around). One row per unhealthy
  service or node: state pill, name, a one-line reason taken from the newest failing
  diagnostic, and "Why →". When there is nothing, it says so in the same space.
- **Services** table: health, running/wanted with a segmented bar, image.
- **Nodes**: state, CPU and memory used against declared capacity.
- **Latest decisions**: the last eight, with actor, action, subject and reason.

### Services and service detail

The list adds "what is happening" (the same one-liner as Needs attention) and the generation.
The detail screen leads with the replicas table, then the spec (environment values masked) and the
decision history for the service and its replicas, each linking to "why at that point".

### Replicas

A wide table inside its own scroll container: replica, service, node, image digest (shortened,
full value in the tooltip and copyable from the record), status, exit reason, generation, and when
it was last reported. A diagnostic in the exit reason column is a link to that replica's Why.
Filter by text and by running or not running.

### Nodes

Declared capacity against used (CPU, memory), lease remaining against its TTL, replica count,
address. A node whose lease expired stays in the list as **lost** for as long as its decisions
are retained, so the failure does not simply vanish from the screen. "Used" is the sum of its
replicas' limits, which is not what the scheduler reserves; see api.md, item 6.

### Why

The core of the product.

```
service broken: 0/1 running                         ← headline, with a state pill
   because ↓
[replica-controller] hold_failed_replica            ← a decision: actor, action, reason, time
   because ↓
[observed] broken-1 on node1: stopped               ← a terminal: the thing that happened
   ┌ error ZBX-E0501  blame: your input             ← a diagnostic block, DIAGNOSTICS.md anatomy
   │ image not found
   │ cause  digest b3:00ff7be1 is not in this node's store
   │ fix    check the digest in broken.zon, or pull the image first
   │ or     then apply the corrected file   $ zcube apply broken.zon   [Copy]
   └ more   zbx explain E0501 · docs …
```

Rules:

1. **It says what the CLI says.** The server computes the chain and the text of each step
   (`/v1/why`). Beside the chain the console shows a terminal block with `zcube why …` output
   built from the same data by `cliWhy()` in `web/js/diag.js`, with a `--verbose` toggle and a
   copy button. The two can be compared at a glance, and a test could compare them byte for byte.
2. **Newest first, each step is the cause of the one above it.** "Because ↓" reads the way the
   CLI's `←` does. The chain ends at a terminal: an observation, an apply, a resync, or an
   expired lease.
3. **The console adds provenance, never claims.** Revision numbers, times, decision ids, links to
   the subject of each decision, who applied. Those sit in small type under the step.
4. **Commands are runnable.** A fix with a command shows it in a terminal-style chip with a
   Copy button. The header always shows the `zcube why …` command for what you are looking at.
5. **Subject picker** (kind, name, with a datalist of what exists) on the screen itself, so the
   page also works as a search. `#/why` with no subject lists services, nodes and the replicas
   that are not running.
6. **History.** `?decision=<id>` shows the chain as it stood at that decision; a banner says so
   and links back to the latest.
7. A subject that no longer exists but still has decisions (retention keeps them 24 hours) says
   "gone" and still explains why it went.

### Decisions

A filterable table of everything the controllers did: when, actor, action, subject, reason, and
what kind of thing caused it. A row opens the Why chain at that decision.

### Codes

The registry as a master/detail list: the text of `zcube explain`, the severity and blame, the
command, and the docs link. Every code badge in every diagnostic links here.

## Diagnostics in the UI

One component, `diagnosticBlock()`, renders every diagnostic: runtime ones inside a Why chain,
store ones in the connection banner, and the console's own.

- **Default view = default CLI output**: severity and code, blame, summary, the innermost cause,
  fixes (commands copyable), `more` (the `explain` command, plus a link to read it here) and
  `docs`.
- **"Show detail" = `--verbose`**: the `while` lines (outermost first), the whole cause chain,
  the context pairs, "(N more not shown)" when the collector dropped something, and the request
  ID. Its open state survives live updates.
- **Blame is always shown, in words and with a shape**: your input, this host or environment, an
  external service, a bug in zcube. A `bug` renders as in DIAGNOSTICS.md: "this is a bug in
  zcube, not something you did", the bundle path, the report link; its internal message appears
  only under "Show detail".
- **Errors the console itself hits are diagnostics, never "Error"**: the API unreachable, a reply
  it cannot read, the store down (the server's own `ZC-E0201`, passed through), a compacted
  watch (`ZC-E0203`, handled without bothering the user, see below). The two codes the console
  raises itself (`ZC-E0102`, `ZC-E0103`) are proposed in api.md and marked "raised by the
  console" in the block.

## Live updates

The console lists once and then follows the watch, the same way an agent does.

1. **Sync.** List `/services/` and take its `revision` R; list `/replicas/`, `/nodes/`,
   `/observed/` at R, and the newest 500 `/decisions/` at R (`reverse=true`). Then
   `GET /v1/watch?prefix=…×5&from=R+1`. Each response applies its events to the mirror in
   `web/js/model.js`, moves the bookmark, and the next watch starts at once.
2. **A second, slower loop** polls `/v1/status` (clock offset, store health) and `/v1/leases` every
   2 s, because keepalives are not revisions.
3. **Compacted watch (`410`, `ZC-E0203`)**: the model lists again and carries on. The header pill
   changes to "Resyncing" for a moment and one line goes into the connection log ("The watch could
   not resume (ZC-E0203). Listing the current state again."). The screen does not flash, no
   banner appears, and nothing the user is doing is interrupted: the mirror is swapped in one
   batch and the views update in place. Visible but quiet.
4. **Connection states**, always in the header, always a word plus a glyph:

   | State | Meaning | Shown |
   | --- | --- | --- |
   | ● Live, rev 412 | the watch is current | green |
   | ◐ Resyncing | relisting after a compaction | blue, no banner |
   | ◐ Reconnecting | a request failed less than 10 s ago | blue, banner with the diagnostic |
   | ▲ Stale, as of 14:02:31 | failing for over 10 s, or the store is down | amber, banner; the data stays on screen |
   | ◌ Connecting | first load | |

   The pill opens a small log of the recent events. While not Live, data is never blanked: it is
   the last data received, and the banner says how old.
5. **A probe after a failure.** After any failure the next watch is `timeout=0`, so recovery is
   shown the moment the server answers, not after a 25 s long poll.

**Updates must not shift layout or steal focus.** The rules the code follows:

- Rows are keyed and updated in place (`keyed()` in `web/js/ui.js`); a row is moved only if the
  sort order changed, because moving a node drops focus.
- A cell is written only if its text changed; a changed cell flashes for 1.4 s (never under
  `prefers-reduced-motion`). Numbers use tabular figures and cells have fixed widths.
- Anything that appears and disappears has reserved space: "Needs attention" has a fixed
  height; the empty states sit in the table's own area.
- Rebuilt regions (the Why chain, the spec) restore focus by `data-fid` and keep the user's
  scroll position and open "Show detail" blocks.
- Nothing calls `focus()` on a live update. Route changes move focus to the page title, except on
  the first load, so the skip link stays the first Tab stop.
- Ages ("12 s ago") are `<time>` elements rewritten in place once a second.
- Screen readers get one polite announcement for navigation and connection changes, not one per
  update.

## Interaction rules

- **Read-only, with the command shown.** The service screen says "To change this service, edit
  its file and run `zcube apply hello.zon`", with Copy. The empty states say how to create the
  first service or node. Fix commands in diagnostics are copyable. There are no destructive
  buttons.
- **Copy** works with the clipboard API and falls back to selecting the text.
- **Tables scroll inside their container**, never the page; the container is focusable
  (labelled) so a keyboard user can scroll it. On a phone, secondary columns hide.
- **Filters survive** navigation and live updates.

### Should `apply` with a diff preview come to the console?

Recommendation: **preview first, apply much later, and never edit in the console.**

- Config lives in git; a console that edits it makes a second source of truth. So the console
  never has a text box for a service spec.
- A **diff preview is read-only in effect** and is what SPEC already promises for the CLI. The
  console could show it for a file the CLI uploaded as a "plan": `zcube apply --plan` stores the
  diff and its hash on the server and prints a console link. The reviewer then sees the diff,
  what would restart or move, and the commands, in a page they can share in a pull request.
- **Apply from the console**, if it ever comes, should mean "apply this git commit", with the
  commit as the audit record, the plan-hash confirmation SPEC describes for destructive commands,
  and a token scope that allows it. That is not before C3 (rollouts and rollback exist), and
  needs api.md items 4 and 5.

## Accessibility

- Landmarks: header, navigation, main; a skip link; one `h1` per screen that receives focus on
  navigation.
- Everything operable by keyboard, with a visible 2 px focus ring that meets contrast in both
  themes. No hover-only information. No keyboard traps.
- **Colour is never the only signal.** Every state is a pill with a glyph and a word (● running,
  ◐ starting, ▲ degraded, ✕ failed, ■ stopped, ○ idle); the replica bar uses a hatched pattern
  for "starting"; diagnostics carry a severity word and a blame sentence.
- Controls have accessible names; tables have headers, and row links say what they are for
  ("Why service broken").
- Live regions are polite and rate limited.
- `prefers-reduced-motion` removes the change flash and all transitions.
- Text uses relative units and wraps; nothing is clipped. Reflows to one column at phone width
  with no horizontal page scroll (only tables, inside their containers).

## Themes and responsive layout

Light and dark come from `prefers-color-scheme`, with a header toggle that cycles system, light
and dark and is remembered in `localStorage` (the page works if storage is blocked). All colour
is tokens on `:root` redefined for dark, as on the site. Three breakpoints: below 960 px the two
columns stack; below 760 px the rail becomes the tab row, secondary columns hide and the dev
panel becomes a bottom sheet.

## Files

```
web/
  index.html            shell: header, navigation, banner, main, live region
  css/console.css       tokens and every component
  js/main.js            boot, mode choice, router, header and connection pill, shortcuts, theme
  js/api.js             client over a transport; turns every failure into diagnostics
  js/model.js           the mirror: list, watch, poll, derived views, attention list
  js/diag.js            diagnostic blocks and the CLI text renderers
  js/ui.js              DOM helpers, keyed rows, pills, copy, formatting
  js/views/*.js         one module per screen
  sim/index.js          the host of the WebAssembly core: frames, virtual time, held watches, traps
  sim/panel.js          the simulation's dev panel
  sim/scenario.js       the seven C0 steps as the panel shows them
  mock/                 the JavaScript mock, for C1 only: engine, fixtures, scenarios, dev panel
```

`sim/zcube_console.wasm` is not in the repository: `zig build console-wasm` builds it, and
`zig build console-site` installs the whole console (`web/` plus the module) to
`zig-out/console`. `zcube-server` embeds the same files.

## Running it

- **Against a server:** start `zcube-server` and open its address. `GET /` and `/console/` both
  serve the console, and `/v1/*` is on the same origin.
- **The simulation:** `zig build console-site`, serve `zig-out/console` with any static file
  server (the module needs the `application/wasm` type; `file://` does not work because the
  browser will not fetch it), and open `/?sim=c0`. `zcube-server` also serves it at
  `/?sim=c0`.
- **The C1 mock:** the same, with `/?mock=c1`.
- **Check it in a browser:** `node tools/browser_check.mjs <base-url> --mode sim|server`
  (Playwright and the installed Chromium; a dev-time tool, not part of the build).

## The simulation, and the mock for C1

`?sim=c0` (also `&speed=4`) loads `sim/zcube_console.wasm`, which is `src/console_wasm.zig`: the
API handlers, the replica controller, the agent's step and `why` of the server, over
`MemoryStore` and `SimRuntime`, on a clock that only moves when the page moves it (real elapsed
time times the speed; frozen means not moving it). The page frames each request, calls
`zc_request`, and holds a long-poll watch itself when the core says `hold_ms`. The bodies are the
core's own JSON, never rewritten.

- **One import.** The module imports exactly `env.zc_panic(ptr, len)`, approved for this build
  only; `tools/console_check.mjs` fails on any other. A panic hands its text to the page, and the
  module traps.
- **A trap discards the instance** (docs/wasm.md, row 9), and the in-browser store with it. The
  page shows a `bug` diagnostic (`ZC-B0001`, with the panic text under "Show detail"), keeps the
  last data on screen, stops time and offers **Reload**, which starts over from an empty cluster.
- **The panel** (bottom right, "Simulated"): Play, Step and Reset; the seven scenario steps, keyed
  to the core's step indexes; speed 1 to 8×; faults: stop the store (`ZC-E0201`, the console goes
  stale), cut the API, "Sleep + compact" (the console is cut off while the core writes and
  compacts its history, then returns to the core's own `410`, `ZC-E0203`), freeze time, restart the
  server core and the agent core. Test hooks: `window.zc.sim` (`forcePanic()` forces a trap).

| Step | What the core does |
| --- | --- |
| 1 | apply `hello` with 3 replicas; three start |
| 2 | `kill -9` one; a replacement starts |
| 3, 4 | scale to 5, then back to 2 |
| 5 | apply `broken` (digest not in the node's store); the chain ends at `ZBX-E0501` |
| 6, 7 | the store goes down (`ZC-E0201`); it comes back |

**What the simulation is not:** real processes, Postgres or SQLite, real time, `zbx`. It shows
what the controllers decide, with every fault under test control (docs/core.md says what the
deterministic simulation proves and does not).

**The mock** (`?mock=c1`) is `web/mock/engine.js`, a small JavaScript model of the store,
controllers, a scheduler and node agents. The core has no C1 yet (no scheduler, no lost-node
detection), so a three-node fleet can only be shown this way: the header says "mock", and the
panel says the fleet is not built in the core. Its C0 scenario was retired when the simulation
covered it. `web/mock/codes.js` (the mock's `explain` text, generated by
`node web/mock/gen-codes.mjs`) is only needed for the mock now: the real core serves `/v1/codes`.

| Scenario | Steps |
| --- | --- |
| `c1` (mock) | three agents join · apply `hello` ×6, two per node · power off node3, its lease expires after 10 s, replicas are rescheduled · node3 rejoins empty · `why node node3` explains no rebalancing |

The mock's panel has Play, Step and Reset, a speed selector, the "open the matching screen"
checkbox and faults (stop Postgres, cut the API, "Sleep + compact", freeze time).

### A case the real C1 tests must cover

An agent that restarts **before its old lease expires** (power off and back on within the TTL).
The new registration is a put under a new lease, so it replaces the key's lease association; when
the old lease later expires it must not delete the new registration. Otherwise the node shows as
lost for good although its agent is running. The mock found this: the store's `commit` now moves a
key off its previous lease on a put. Also check that the restarted agent reports the replicas it
can no longer find as `lost`, and that the controller replaces them. `node3` ends up registered
and the service back at 6/6 for any restart gap, shorter or longer than the TTL.

To regenerate the mock's explanation texts from the registry: `node web/mock/gen-codes.mjs`.
