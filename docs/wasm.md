# The control-plane core on WebAssembly: what the spike found

> **Update, C0 slice 5a.** The core/shell rule below is adopted (AGENTS.md) and the controllers,
> the agent's step, the API handlers, `why` and a simulated runtime are written to it: see
> [core.md](core.md). What building them taught is in "What slice 5a taught", at the end.

**Status: output of the C0 slice 4 spike (2026-10-26).** The owner wants the console demo to run the
*real* controllers, scheduler and store in the browser, with a simulated runtime, instead of the
JavaScript mock in `web/mock/engine.js`, and wants the attempt to teach us what our "pure" code
assumes. So this slice made one thing true and then probed everything around it: **the modules
that should be pure compile to `wasm32-freestanding` and run in a WebAssembly host**
(`zig build wasm`, `zig build wasm-check`). This file is what came out of it. Nothing here
changes an approved contract.

## The short version

- **The pure modules already were.** `store.zig`, `store_memory.zig`, `runtime.zig`, `clock.zig`,
  `constants.zig`, `text.zig`, `store_failures.zig`, Zigcube's diagnostics, and Zigbox's
  `diagnostic`, `product`, `render` and `explain` compile for `wasm32-freestanding` with **no
  source change** to any of them, and the scenario runs in Node (`zig build wasm-check`, 564 bytes
  of rendered diagnostics checked). The discipline of "everything through `Store`, `Runtime` and
  `Clock`, explicit integer widths, no allocation but the one you are handed" is what made it so.
- **Their tests run there too.** The 30 unit tests of those modules pass on `wasm32-wasi`
  under Node's WASI (`zig build wasm-test`): a 32-bit address space, one thread, and the testing
  allocator still checking for leaks.
- **The things that do not fit are exactly the ones the shell owns:** threads, `std.Io`, libc,
  the two SQL backends, `zigbox`'s runtime half, a real clock, and a panic message. The failures
  are crisp compile errors, listed below, so the line between core and shell can be drawn by the
  compiler.
- **What the spike taught that the compile did not:** `Watch.next(timeout_ms)`,
  `Runtime.events(timeout_ms)` and `Runtime.stop(grace_ms)` are *blocking* calls in the contracts,
  and a core on one thread in a browser cannot block. The memory store already ignores the timeout.
  Controllers therefore have to be written as steps (do what is due, say when to wake), with the
  shell doing the waiting. See "Observations about the approved contracts".

## What was built

| Piece | Where | Notes |
| --- | --- | --- |
| `zig build wasm` | `build.zig` | Compiles `src/wasm_core.zig` for `wasm32-freestanding` into `zig-out/wasm/zcube_core.wasm`. `-Doptimize=` is honoured. |
| The core list | `src/core.zig` | The modules that must stay pure, and `reference_all()`, which forces every public declaration of each to be analysed (see "How `zig build wasm` keeps it honest"). |
| The doorway | `src/wasm_core.zig` | Three exports: `zcube_smoke`, `zcube_report_ptr`, `zcube_report_len`. The only wasm-specific code; it picks `std.heap.wasm_allocator`. |
| The scenario | `src/core_smoke.zig` | A put, a watch, a lease that lapses on an injected clock (with `lease_list`), compaction and its `Compacted` refusal, and a `ZC-` and a `ZBX-` diagnostic rendered into a buffer. It also runs natively as a test. |
| `zig build wasm-check` | `tools/wasm_check.mjs` | Instantiates the module with **no imports**, calls `zcube_smoke`, and checks the step it returns (0) and the rendered text. |
| `zig build wasm-test` | same file, `--wasi` | Runs `src/core.zig`'s test binary, built for `wasm32-wasi`, under Node's WASI. |
| CI job `wasm` | `.github/workflows/ci.yml` | `wasm-check` in Debug and in ReleaseSafe, and `wasm-test`. |

**Why JavaScript for the runner.** `docs/STYLE.md` prefers Zig tooling. I looked for a Zig-only way
to execute a `.wasm`: Zig's standard library has none, `zig test -target wasm32-wasi` can only run
through an external `--test-cmd` runtime, and neither wasmtime nor wasmer is installed here or on
the GitHub runner. Node is installed in both (the browsers' engine family), so `tools/wasm_check.mjs`
is a ~80-line file that imports only `node:` modules, holds no logic of the core, and says the same
at its top. The build, the choice of what to run and every line of the core stay Zig.

## What did not compile or did not work, and what it reveals

Each row is something I tried for `wasm32-freestanding` (or `wasm32-wasi` where noted). "Probe"
means a scratch file outside the repository; the error text is Zig 0.17.0's.

| # | Attempt | Result | Design assumption it reveals |
| --- | --- | --- | --- |
| 1 | `std.Thread.spawn` in a core function | `error: Cannot spawn thread when building in single-threaded mode`, and `Unsupported operating system freestanding` | The core cannot start threads. Nothing in it does; the rule is now compile-checked (negative control below). `std.heap.smp_allocator` fails the same way. |
| 2 | `std.Io.Threaded` (the real `std.Io`) | `posix.system has no member named 'getrandom'`, `'IOV_MAX'`: it does not compile | **There is no `std.Io` to hand out.** Every API that takes `std.Io` is shell: `SqliteStore.open(io, …)`, `PostgresStore.open(io, …)`, `std.Io.Mutex`. The core uses `std.Io.Writer`/`Reader` (plain fixed buffers, in `text.zig` and `diag.zig`), which are fine; the rule is "no `std.Io` *value*". |
| 3 | `std.Io.Mutex`, `std.Io.Clock.real.now` with `std.Io.failing` | Compiles, but there is no working `Io` to pass it | A mutex is meaningless on one thread. `MemoryStore` has none (it is documented as single-threaded; the conformance harness wraps it in `Serialized`). A real clock call compiles and then has no source of time. |
| 4 | `std.testing` anywhere (`zig test -target wasm32-freestanding`) | Fails inside `std.Io.Threaded`, as in row 2 | **Unit tests cannot run on freestanding**: `std.testing.io` pulls in `Threaded`. They compile and run on `wasm32-wasi` (30 pass), so `wasm-test` exists. The conformance suite uses threads and racing writers; it cannot run on either (see the open question). |
| 5 | `std.atomic.Value(u64)` | `expected 32-bit integer type or smaller; found 64-bit integer type` | Baseline wasm32 has no 64-bit atomics. The core uses no atomics (`grep` finds them only in the conformance suite). `Revision` and every millisecond count are `u64`, which is fine as plain data. |
| 6 | `std.heap.c_allocator` | `C allocator is only available when linking against libc` | No libc. The store takes its allocator as an argument (`MemoryStore.init(gpa, clock)`), which is why the doorway can choose `wasm_allocator` and the core never names one. |
| 7 | `std.heap.wasm_allocator` **natively** | `unimplemented` (it needs `single_threaded`) | The doorway is wasm-only by nature. That is why `wasm_core.zig` is not in the native test root and the scenario lives in `core_smoke.zig`, which is. |
| 8 | `std.debug.assert(false)`, `@panic`, an out-of-range index | Debug and ReleaseSafe: `RuntimeError: unreachable`, **with no message**. ReleaseSmall: the assertion is gone (`assert(false)` returns, `a[9]` reads 0) | Panic text has nowhere to go (no stderr), so "a panic becomes a `bug` diagnostic" (DIAGNOSTICS.md) is the shell's job: a root `panic` that calls a host import. And STYLE's "ReleaseSafe, never ReleaseSmall" is not pedantry: ReleaseSmall silently removes the checks the design relies on. A wasm build that ships must be ReleaseSafe. |
| 9 | A trap, then calling the module again | `memory access out of bounds` on the next, unrelated call | A trap does not unwind `__stack_pointer`. **After a trap the instance is poisoned** and must be discarded; in the browser demo that also discards the in-memory store. |
| 10 | Stack | 1 MiB (`__stack_pointer` starts at 1048576); overflow is a clean `memory access out of bounds` trap, not corruption | Sizes (bytes): `Diag` 5,604; `Diagnostic` 5,800; `ExitReason` 5,808; `StatusChange` 5,876; **`MemoryStore` 137,304** (256 inline watch slots with a 512-byte prefix each). The scenario heap-allocates the store. Anything that puts a few `Diagnostic`s and a store on the stack is near the budget in Debug. |
| 11 | `@sizeOf(usize)` | 4. The 30 unit tests pass on wasm32-wasi | STYLE's "explicit `u32`/`u64`, `usize` only for indexing" is what made the 64-bit-revision, 32-bit-address combination a non-event. |
| 12 | `export fn f(io: std.Io)`; slices, unions, arenas | `parameter of type 'Io' not allowed in function with calling convention 'wasm_mvp'` | A wasm export takes integers and pointers only. The core's API (slices, unions, arenas) is not callable from JavaScript as it stands; a doorway must be flat. A `u64` crosses as a `BigInt`. This favours the "API handlers as functions from request bytes to response bytes" shape (JSON in, JSON out). |
| 13 | `zigbox` as a dependency built for `wasm32-freestanding` | Works: `b.dependency("zigbox", .{ .target = wasm32-freestanding, … })`. `diagnostic`, `product`, `render`, `explain`, `diag`, `codes` compile and run. `zigbox.host` (the interface), `HostReal` and `HostSim` (as types) compile too | The `zigbox` module's root imports host code (`host_real`, `runtime/run`, run records, D-Bus), and none of it is a problem **only because Zig analyses what is referenced**. |
| 14 | `zigbox.start` (the container runtime) | `posix.system has no member named 'S'` in `runtime/run.zig` | The simulated runtime for the browser must implement *Zigcube's* `Runtime` interface; it cannot wrap Zigbox's. The agent's adapter that does wrap it is shell. |
| 15 | `store_sqlite.zig`, `store_postgres.zig`, `pq.zig` | `no module named 'sqlite_c'` / `'libpq_c'`. `zig translate-c -target wasm32-freestanding` works for `sqlite3.h` but fails for `libpq-fe.h` (host libc headers: `gnu/stubs-32.h`) | Even with headers, there is no `libsqlite3` or `libpq` to link. A browser store is `MemoryStore` (or, later, a store written for the browser's own storage), not a port of these. |
| 16 | `tidy.zig`, `pg_dev.zig`, the three executables | `std.Io.Threaded` fails to compile (row 2) | They are programs (`std.process.Init`, files, child processes). Shell by definition. |
| 17 | Lazy analysis | A banned call in a `pub` function nobody calls was **not** an error until `core.reference_all()` forced it | Compiling "the library" proves only what the library reaches. See below. |

**Negative control for row 17.** With `reference_all()` in place I added a `std.Thread.spawn` to an
unused `pub fn` in `store_failures.zig`, and to a new `pub` method of `MemoryStore`: both fail
`zig build wasm` with the error of row 1. Without `reference_all()` neither did. I removed them
(they are not in the repository).

## What I changed to make it work

Very little, which is the finding. In existing code:

- **Nothing in `store.zig`, `store_memory.zig`, `runtime.zig`, `clock.zig`, `constants.zig`,
  `text.zig` or `store_failures.zig`** was changed for wasm. (This slice also added `reverse` and
  `lease_list` to the store, and a doc tweak to `runtime.zig`, for other reasons; both compile for
  wasm and `lease_list` is in the scenario.)
- **Diagnostics moved onto Zigbox's types** (same slice, separate commit): `Diag` keeps the `ZC-`
  registry but its item types and `Diagnostic` are Zigbox's, and the renderer is Zigbox's. This is
  what makes a `ZBX-` diagnostic render with `zbx explain` inside a `ZC-` failure, and it compiles
  for wasm as is (row 13).

New files:

- `src/core.zig`: the list of core modules, `reference_all()`, and a test that pulls in every
  module's tests.
- `src/core_smoke.zig`: the scenario, natively tested.
- `src/wasm_core.zig`: the doorway (`std.heap.wasm_allocator`, three exports).
- `tools/wasm_check.mjs`, `build.zig` steps `wasm`, `wasm-check`, `wasm-test`, the CI job, `tidy`
  allowing the `zigbox` import, `zig-pkg/` in `.gitignore`.

## What I did not change, because it belongs to the shell

- `store_sqlite.zig`, `store_postgres.zig`, `pq.zig`, `sqlite_c.h`, `libpq_c.h`: C libraries and
  `std.Io.Mutex`.
- `store_conformance.zig` and its harness (`Serialized`, `Connection`, racing writer threads,
  `std.testing.io`), `pg_dev.zig`, `tidy.zig`.
- `zcube.zig`, `zcube_server.zig`, `zcube_agent.zig` (`std.process.Init`, files, later sockets).
- A real clock. No `RealClock` exists yet; the SQL backends take the `Clock` seam and Postgres
  reads its own. The shell will supply a monotonic one natively and `Date.now()` through a host
  import in the browser.
- A panic handler that reports through the host, and any host import at all. The smoke module has
  none, and `wasm_check.mjs` fails if one appears, so a new import is a deliberate act.
- The simulated runtime, controllers, scheduler and API handlers: later slices, and they will be
  core.

## Observations about the approved contracts (reported, not changed)

Nothing in the spike required a contract change, and none was made. Four things are worth the
owner's attention before the server slice:

1. **Three calls block in the contracts.** `Watch.next(timeout_ms)` ("waits up to `timeout_ms`"),
   `Runtime.events(timeout_ms)` and `Runtime.stop(grace_ms)` ("returns once it has stopped"). The
   memory store already answers at once ("Deterministic: report what is ready now"), and a
   simulated runtime can do the same with virtual time. The consequence is for the controllers:
   they must not loop waiting on these. Written as steps, with the shell doing the waiting, they
   run unchanged on a thread, on the server's event loop and in a browser. No signature changes.
2. **`ExitReason` carries a `Diagnostic` by value (5.8 KB), so `Status`, `Listing` and
   `StatusChange` do too.** One `Runtime.list` of the 512-handle maximum is about 3 MiB of the
   16 MiB request arena. That fits; it is also the number that decides the browser's memory.
3. **The memory store's allocation failure is not rolled back** (its header says so). In a server
   that is a test-only caveat; in a browser, running out of memory is a realistic event, and
   `NoCapacity` there leaves a half-updated store. The wasm host should treat it as fatal and
   restart the instance.
4. **`Store`'s "may be used from several threads" is not true of `MemoryStore`** on its own (it is
   single-threaded by design and documented so). It is true of every backend the server uses. No
   change: the core only ever needs the single-threaded reading, which is the weaker one.

## Proposed core/shell rule (for the server slice)

> **The core** is the controllers, the scheduler and the API handlers, written as functions over
> `Store`, `Runtime` and `Clock`, plus the types, limits and diagnostics they share. It has no
> threads, no sockets, no files, no libc, no `std.Io` value, no real clock, no source of randomness
> and no blocking call. It allocates only from an allocator or arena it is given. It reports every
> failure as a `Diag`.
>
> **The shell** is everything that touches the machine: the HTTP server, the Postgres and SQLite
> backends, the agent's adapter around `zigbox`, the CLI, threads, the real clock, signal and
> panic handling, and process start-up. The shell may import the core; **the core never imports
> the shell**.

What follows from it, concretely:

- **A controller is a step.** `reconcile(ctx) -> Wakeup`, where `ctx` holds the `Store`, the
  `Runtime`, the `Clock`, an arena and a `Diag`, and `Wakeup` says "when you next need me": a time,
  and the key prefixes whose change should wake me. It does what is due and returns. The shell
  loops, waits (on a `Watch`, on a timer) and calls it again. Level-triggered reconciliation
  (HANDOFF) is already this shape.
- **An API handler is a function from bytes to bytes**: request in, status and JSON out, plus the
  `Diag` for a failure. The HTTP server is a loop that reads a request, calls it and writes the
  reply; the browser calls it directly. This also gives the flat export wasm needs (row 12).
- **Time is a `Clock`, identity is a parameter.** Decision ids use the time, a controller-instance
  number and a counter (`docs/keys.md`); the instance number comes from the shell, as does any seed.
  Nothing in the core asks the machine for either.
- **Memory is bounded in the core already** (`request_arena_bytes_max`); the shell allocates the
  arena. In the browser the arena is the wasm heap, which can grow and never shrinks.
- **Where a core module needs something the machine provides, it takes an interface** (`Clock`,
  `Store`, `Runtime`), never a feature test. If a second kind of interface is ever needed (a host
  import for a random seed, for logging a panic), it is added as an explicit field of the context,
  so the list of what the core can ask of its host stays short and written down.
- **`ReleaseSafe` for anything that ships**, in wasm as elsewhere (row 8).
- **A trap means discard the instance** (row 9). State that must survive lives in the store, and
  in the browser that is the instance's own memory, so it is lost too: say so in the demo.

## How `zig build wasm` keeps it honest

1. **The core list is the contract.** A module is core because it is in `src/core.zig`. `zig build
   wasm` compiles the doorway, whose `comptime` block calls `core.reference_all()`: the address of
   every non-generic public function of every listed module and of the types they declare is
   taken, so all of it is analysed and generated for `wasm32-freestanding`. A thread, a file, a
   libc call or a `std.Io` value in any of it fails the build (negative control above).
2. **Zero imports.** `wasm_check.mjs` instantiates the module with an empty import object and
   fails if the module asks for any. A function the core calls on its host is a finding.
3. **The scenario runs.** The result is the step it stopped at; the rendered text is compared. The
   same scenario is a native test, so the two runs can be compared.
4. **Two build modes in CI.** Debug, and ReleaseSafe (the mode that ships). ReleaseSmall also
   passes locally but is not run, because it removes assertions.
5. **The core's unit tests run on wasm32-wasi** (`wasm-test`): 32-bit `usize`, one thread, leak
   checking.
6. **A dependency bump is checked too.** The wasm build instantiates the `zigbox` package for
   the wasm target, so a Zigbox change that makes the diagnostics reach for the OS shows up here.

What it does **not** catch, so reviewers should:

- Private functions that nothing reaches, and generic (`anytype`) functions until something
  instantiates them. Types nested more than two levels down are not walked.
- Semantics: a core function that loops waiting for a store change compiles fine and hangs in a
  browser. The rule is "steps, not waits", enforced by review and by the first controller test
  that runs on the memory store with a manual clock.
- `usize`-width and endianness surprises beyond what the unit tests exercise.
- The conformance suite, which cannot run on wasm (below).

## Open questions for the owner

1. **Run the conformance suite against the memory store on wasm?** It needs threads and `std.Io`.
   A single-threaded subset (CAS, watch ordering, lease expiry, compaction, the model test) could
   run under WASI the same way `wasm-test` does, and would prove the memory store's semantics in
   the very environment the browser uses. It means splitting the racing tests from the others.
   Not done: out of scope for a spike.
2. **Should Zigbox export its diagnostics as a module of their own?** Today `zigbox` is one module
   whose root imports the runtime and the host. It works for wasm only through lazy analysis.
   A separate `zigbox_diag` module would make "pure" a property of the package, not of the
   compiler's laziness. It is a request to the Zigbox owner, not something to do here.
3. **A host import for panics in the browser build?** It is the one import I would allow, because a
   trap with no message is a poor way to find a bug. It changes "zero imports" to "exactly one,
   named", and needs a root `panic` declaration. Decide when the browser demo is built.

## Running it

```
zig build wasm                                  # zig-out/wasm/zcube_core.wasm
zig build wasm-check                            # run it in Node (Debug)
zig build wasm-check -Doptimize=ReleaseSafe     # the mode that ships
zig build wasm-test                             # the core's unit tests under WASI in Node
```

Sizes on this machine: 1.3 MB Debug, 607 KB ReleaseSafe, 62 KB ReleaseSmall (not for shipping).

## What slice 5a taught

- **The core is bigger than the spike, and the rule held.** About a dozen modules (controllers,
  agent step, API, `why`, the simulated runtime, the simulation) compile for `wasm32-freestanding`
  with zero imports. The things that tried to pull the shell in were all in tests or debugging:
  `std.debug.print` (it reaches `std.Io.Threaded`, row 2: a stray one in a core function fails the
  build), and `std.testing`, which is why test files are listed only in `core.zig`'s `test` blocks
  and not in `modules`.
- **`usize` hides in random draws.** `random.uintLessThan(usize, n)` consumes different bits on
  32 and 64 bits, so a seeded fuzz run diverged between native and WASM. The native-versus-WASM
  comparison of `zig build sim-c0` (the report ends in a hash of the whole store) caught it at once;
  draw with `u32`.
- **Native and WASM agree byte for byte** for the scenario and for the fuzz variant, for the seeds
  checked in CI. That includes the order of everything the core does: nothing in it depends on
  pointer values, hash-map iteration order or the address space.
- **The memory store is a reference, not a fast store.** `list` replays its log, and lookups are
  linear, so a long simulation is dominated by it (hundreds of thousands of keys is slow even in
  ReleaseSafe). The world compacts once a minute, as the server will, and retention reads the index
  a page at a time; both exist because the profile showed the cost there and not in the controllers.
- **A trap still poisons the instance.** `wasm_check.mjs` instantiates a fresh module per run
  for that reason. `ReleaseSafe` remains the mode that ships.
- **The conformance suite's single-threaded half runs under WASI** (`zig build wasm-test`), against
  `MemoryStore`, the store the browser would use: the racing tests stay native.
- **Still not done:** the one named host import for panics (slice 5b, with the browser demo), and a
  real clock for the browser (`Date.now()` through a host import, or the host passing the time in).
  The core's `Clock` must be Unix milliseconds for decision times to mean what keys.md says.

## Running the simulation

```
zig build sim-c0                          # native and WASM, seed 1, compared byte for byte
zig build sim-c0 -Dseed=7 -Dops=300       # another seed, a longer fuzz run
zig build sim-c0-exe -Doptimize=ReleaseSafe && zig-out/bin/sim_c0 7 fuzz 300
```
