# Diagnostics plan: how Zigcube gets the shared `Diag`

Status: **option D accepted by the owner (2026-10-26).** Zigbox must change so a second
registry (`ZC-` codes) plugs into its diagnostics and renderer; the precise change to ask for is
in `docs/diagnostics-zigbox-proposal.md`. The `zigbox` dependency is not added until that lands
and something uses it. Until then, the contracts are written
against the local shim `src/diag.zig`, and only a `ZC-` registry stub exists
(`src/diag/codes.zig`). Nothing here edits `DIAGNOSTICS.md`.

## What I found in Zigbox's code (`Zigbox/zigbox` main, 2026-10-25)

1. **`Diag` is tied to one registry.** `Diag.code` is `?codes.Code`, and `Code` is a closed
   `enum(u8)` of the 30 `ZBX-` tags (`src/diag/codes.zig`). `raise` takes that enum. A `ZC-`
   code cannot be named, let alone stored, without editing Zigbox's registry or changing the
   type. Putting `ZC-` codes into Zigbox's file would mix two products' registries in one
   repo, so I do not propose it.
2. **The renderer is tied to `ZBX` too.** `codes.full_name` builds `"ZBX-" ++ tag`;
   `render.zig` strips `[4..]` to get the tag for `zbx explain`, hard-codes the report URL
   (`github.com/Zigbox/zigbox/issues/new`), the `zbx explain` and `zbx bundle` hints, and the
   docs base URL; `constants.diag_code_bytes` is `4 + 5`.
3. **What is reusable.** The *collector* (bounds, sanitising, overflow policy) and the
   *rendering rules* (default, verbose, JSON) are exactly what DIAGNOSTICS.md describes for both
   products. Only the registry and a handful of strings are product-specific.
4. **The `zigbox` module exposes `diag`, `codes` and `render`** as namespaces, not as
   something parameterised by a registry. So a second registry cannot be plugged in
   *without a change to Zigbox*.
5. **A runtime failure arrives as Zigbox's `Diag`**, with a `ZBX-` code, inside
   `ExitReason.start_failed`. The agent must put it on the observed-state key, and
   `zcube why` must render it next to `ZC-` diagnostics. So whatever Zigcube's own `Diag` is,
   there has to be a registry-independent form that carries either product's code. I wrote it:
   `src/diagnostic.zig` (`Diagnostic`, plain data, code as text).

## A consequence for the instruction "adopting the real one only changes an import"

That holds only if Zigbox's `Diag` can carry `ZC-` codes. Today it cannot, so swapping the
import would not compile the moment `raise(.E0201)` names a Zigcube code. Either Zigbox's
`Diag` changes (option B), or Zigcube keeps its own collector (options C and D). I kept the
shim's surface identical to Zigbox's anyway (`raise`, `cause`, `while_`, `context`, `fix`,
`fix_with`, `entry`, `exit_code`, `last_cause`, `reset`, `save_bundle`), so every call site in
Zigcube reads the same under all four options.

## Options

**A. Add `ZC-` codes to Zigbox's registry.** One type, no work. Rejected: Zigbox would ship
Zigcube's codes, the numbering rules in DIAGNOSTICS.md (separate prefixes per product) lose
their meaning, and every Zigcube code change would need a Zigbox release.

**B. Make Zigbox's diagnostics registry-generic (upstream change), depend on `zigbox`.**
`Diag` and `render` take the registry (and a small `Product` record: prefix, command name,
report URL, docs base) at comptime. Zigcube supplies `ZC-`. One implementation, one set of
rendering rules, no drift. Costs: a refactor of the canonical repo that touches every
`codes.Code` use in Zigbox, timed against its M2; and `Diag(ZBX)` and `Diag(ZC)` would still be
different types, so the agent still needs the plain-data `Diagnostic` at the runtime boundary.
Making `Code` a runtime `{product, tag}` pair instead would let one `Diag` hold both, but
needs Zigbox to know the registries of every product at link time.

**C. Zigcube keeps its own collector and renderer** (the shim becomes the real thing, with the
renderer ported from `src/diag/render.zig`). No change to Zigbox. Costs: roughly 340 lines of
collector and 540 of renderer copied; drift risk. Mitigation: a test (needs the `zigbox`
dependency) that renders the same diagnostics through both renderers and compares bytes.

**D. Share the data form and the renderer, keep collectors per product** (recommended).
Zigbox's diag module gains (1) the plain `Diagnostic` type with JSON write and parse, which is
the interchange DIAGNOSTICS.md already requires between node, API and CLI, and (2) a `render`
that takes a `Diagnostic` and a `Product` record instead of a `*const Diag`. Each product keeps
its own small `Diag` collector and registry, converting with `Diagnostic.from_diag` (already
written here in `src/diagnostic.zig`) before it crosses a boundary. `zcube why` then renders a
`ZBX-` diagnostic that came off a node and a `ZC-` one from the server with one renderer.
Costs: a smaller upstream change than B (the collector is untouched), but still a change.

## Recommendation

**D, reached through C.** Step 1, now, no decision needed: keep the shim; contracts use `*Diag`
for Zigcube's own failures and `Diagnostic` for anything that crosses the runtime boundary.
Step 2, owner decides: ask the Zigbox owner whether they will take the `Diagnostic` plus
`Product`-parameterised `render` change. If yes, Zigcube depends on `zigbox` and deletes its
renderer before it is written. If no, Zigcube ports the renderer (option C) in the slice that
needs it, with the cross-check test.

On the dependency itself: `docs/STYLE.md` already lists the `zigbox` package among Zigcube's
dependencies "for the runtime and the shared diagnostics", and the agent needs it regardless.
HANDOFF reserves dependency decisions for the owner, so I have **not** added it. If approved,
the form I would use is a `build.zig.zon` entry pinned by URL and hash to a Zigbox commit
(`.lazy = true`, so `zcube-server` and `zcube` builds do not fetch it until used), plus the
reason in the commit message. The module needs no libc and brings `build_options` along itself.

## What exists now

- `src/diag/codes.zig`: the `ZC-` registry, 10 codes, with the build-time checks of
  DIAGNOSTICS.md (every tag registered once, kind letter matches severity, blame matches
  severity, summary and explanation well formed). Used by the `Store` and `Runtime` contracts.
- `src/diag.zig`: the shim, a copy of Zigbox's collector pointed at that registry (same bounds,
  same overflow policy, same tests adapted).
- `src/diagnostic.zig`: `Diagnostic`, the plain-data form, with `from_diag`.
- Not written, by instruction: the renderer, `zcube explain`, bundles, the docs pages, golden
  tests, the no-stack-trace CI check, redaction.
