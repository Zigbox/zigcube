# Review checklist

The supervisor reviews every slice against this list, so run it yourself first, on your own diff, before you report. Each item is here because a review or a demo found it in C0, or because Zigbox's list (canonical for the shared parts) has it. Say in your report which items your slice touched and what you checked; an item that does not apply needs no word. Add an item when a review finds the same thing twice.

## Interfaces that others read

- **A JSON schema only grows.** Under the same version, never remove, rename or retype a member, and never change what it means. Add members beside the old ones; a change that cannot be additive is a new version, with the old one still documented. This covers the API (`docs/api.md`), `-o json`, bundles and stored values.
- **A stored value is read by the next release, and by the one after.** Bump its version when the format changes, keep reading every older version, and test that with real text an older build wrote.
- **Every new command, flag, endpoint and diagnostic is in `--help`, `docs/api.md` or `docs/cli.md`, the goldens and the error pages** in the same commit. `zig build errors-site-check` catches pages; nothing catches the rest.
- **`Store` and `Runtime` are approved contracts.** A change to either is on HANDOFF's **Ask first** list, and so is a key layout that works on one backend only.

## Authority and concurrency (`docs/authority.md`)

- **Every write comes from its prefix's one writer role** (the table in `authority.md`). A new prefix gets a row there first.
- **The read-set rule.** A transaction compares every key that justified the action, and a predicate over a set compares the one authoritative aggregate (`/allocations/<node>`), never the members it happened to read.
- **Intent never lives on a node.** The state dir holds process facts only; anything a node needs to decide comes from the store.
- **A decision is immutable and cites its evidence.** Counting goes in `/decision-summaries`, which is never cited as a cause.

## Backends

- **Every backend gives the same answer, in the same order.** A query that returns several rows says its order (`ORDER BY`); SQLite's compaction once relied on row order it was never promised. The conformance suite runs on memory, SQLite and Postgres; a store change runs all three.
- **The core stays `wasm32-freestanding`-clean.** No threads, sockets, files, libc, `std.Io` value, real clock or blocking call in a module listed in `src/core.zig`. `zig build wasm-check` and `wasm-test` prove it; the console module is checked under both V8 compilers (one of them crashed on code the other ran).

## Processes, sockets and time

- **Every exit path is tested**, not only the clean one: a refusal, a timeout, SIGKILL of a child, and SIGKILL of the process itself. Anything it starts or holds (a supervisor, a port, a lock, a Postgres) is released on each, or adopted on restart.
- **A blocking read has a deadline that is not a crash.** A socket timeout made the standard library's reader panic (`ZC-B0001`, 1 run in 6); poll before each read.
- **A server can restart on its port at once.** Listen with `SO_REUSEADDR` alone (not the std option, which adds `SO_REUSEPORT`), and test the restart after a connection the server closed first.
- **An identifier that must be unique has a random part.** Counters restart with the process; request IDs once collided across runs.
- **Time comes from `Clock`.** In the core, never a real clock; in the agent, fencing deadlines use `CLOCK_BOOTTIME`, which counts suspend.

## Diagnostics

- **Every failure is one coded diagnostic** with a cause and a fix (`DIAGNOSTICS.md`). An `errno` alone, an empty reason, or a line that blames the wrong layer is a bug, including in the test harness.
- **A `ZC-B` code means our bug.** Never use it for something an operator or the environment can cause.

## Tests and gates

- **The gates run on the exact commit you report**: `zig build check` (AGENTS.md), with its last line pasted.
- **A test reachable from no test root never runs.** A new file of tests is imported from a root in `build.zig`, and you have seen it run (`zig build test --summary all`).
- **A test fills memory with a known byte before checking that something wrote it.** Never rely on what `undefined` holds.
- **A fixture parsed from text is checked against real output**, captured from a real run, not written from what the code is believed to print.
- **A simulation is never called a demo.** `sim-cN` and `agent-smoke` are checks; only `demo-cN` passing in CI demonstrates a milestone.
- **CI conditions fail safe.** A job guarded by a condition runs when the guard cannot decide (`!cancelled()`, never `always()`; an empty diff counts as code).
