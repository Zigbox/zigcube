# Zigcube style and testing

Zigcube uses Zigbox's style and testing rules, copied below from `Zigbox/zigbox` `docs/STYLE.md`. The rules in **Where Zigcube departs** override the copied text; everything else applies as written, reading "Zigcube" for "Zigbox". Keep the copy in step with Zigbox when its STYLE.md changes.

## Where Zigcube departs

Zigcube is a networked server, CLI and agent rather than a single-shot static binary, so a few of Zigbox's rules don't fit. Each departure has its reason.

- **libc is allowed** in `zcube-server` and `zcube` for the Postgres (libpq) and SQLite client libraries that HANDOFF.md expects. `zcube-agent` links the `zigbox` module, which is libc-free; keep libc out of the agent's runtime path unless a store backend needs it there.
- **Allocation.** Startup allocation plus bounded per-request or per-reconcile arenas, freed whole when the request or pass ends. Every arena has a named size limit in `src/constants.zig`, and exceeding it is an operating error with a coded diagnostic. No unbounded growth: caches, watch buffers and queues all have named limits.
- **Dependencies.** Beyond the Zig toolchain: libpq, SQLite and the `zigbox` package (for the runtime and the shared diagnostics). Any other dependency needs a written reason in its commit message and the owner's approval first.
- **Simulation.** The seam for deterministic simulation is the `Store` and `Runtime` interfaces plus a clock and network seam, not Zigbox's `host.zig`. Controllers and the scheduler must not know which implementation they are using. The store conformance suite plays the part of Zigbox's store simulator.
- **Threads (provisional, set in C0 slice 2; the owner has not set a rule yet).** `std.Thread` is
  allowed in tests and inside a store backend, and nowhere else until the owner decides how the
  server and the agent are structured. Shared state in a backend sits behind one mutex
  (`std.Io.Mutex`, which needs an `std.Io`, so a backend's `open` takes one); a wait sleeps outside
  the mutex. No test spawns a thread it does not join.
- **Randomised and racing tests (provisional, same slice).** All randomness in a test comes from
  one seed, drawn once per run, printed once at the start, and replayed with `-Dseed=N` on the
  build step. Where real threads race, the interleaving is the machine's, so those tests assert the
  invariants that hold for every interleaving (no gap, no duplicate, revision order equals commit
  order, every event delivered once and in order) and never one particular order. A test step
  that draws its seed at run time is never cached: every CI run is a new draw.
- **Store backend allocation.** A backend's client library (SQLite, libpq) allocates inside the
  library; that is outside "no allocation after startup". What the backend hands to its caller is
  copied into the caller's arena, so `request_arena_bytes_max` bounds a request, and a result that
  does not fit is `error.NoCapacity`.
- **`zig build tidy`** is Zigbox's checker, ported. libc may be linked here, so its libc rule is
  gone; the C libraries' translated headers are importable modules; and the average of two
  assertions per function is checked by review, not yet by the tool.
- **Demo tests.** `zig build demo-cN` runs against real Postgres and SQLite with `FakeRuntime` until real Zigbox drops in. From C1 on, nodes may be agent processes on one machine or VMs, as HANDOFF.md says.

## Zigbox's rules (copied)

Zigbox adopts [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md), TigerBeetle's coding style, and TigerBeetle's testing approach: deterministic, seeded simulation with fault injection. Read TigerStyle in full once. This file says how it applies here and where Zigbox departs from it, with the reason each time.

Design goals, in order: **safety, performance, developer experience.**

### Rules (enforced by review; mechanical ones also by `zig build tidy`)

#### Control flow and limits

- Simple, explicit control flow. **No recursion.** Tree walks (store import, verify, gc) use an explicit stack with a fixed maximum depth.
- **Put a limit on everything.** Every loop, queue, buffer, path, file read and directory walk has a named upper bound in `src/constants.zig`. Exceeding a bound is an operating error with a one-line message, never undefined behaviour.
- A loop that cannot terminate by design (signal-forwarding wait loop) asserts that fact.
- Explicitly sized integer types (`u32`, `u64`). `usize` only where the language demands it (slice indexing, lengths), converted at the boundary with a checked cast.

#### Assertions

- Assertions catch programmer errors; operating errors (missing file, `EPERM`, a bad image) are handled and reported. A failed assertion crashes. That is the correct response to corrupt code.
- **At least two assertions per function on average**: arguments, return values, pre- and postconditions, invariants.
- **Pair assertions**: check each important property on two paths, for example a tree digest when writing to the store and again when reading it back.
- Assert the **positive space and the negative space**: what must hold and what must not.
- Split compound assertions: `assert(a); assert(b);`, not `assert(a and b)`. Use `if (a) assert(b);` for implications.
- **`comptime` assert the relationships between constants** in `constants.zig`.
- Assertions stay on in release builds. Zigbox ships `ReleaseSafe`, not `ReleaseSmall`. The M0 size limit (under 2 MB) is checked against the `ReleaseSafe` binary. If it cannot be met, report that to the owner; do not switch build modes quietly.

#### Memory

- **No allocation after startup.** Each command computes its memory need from `constants.zig`, allocates once (or uses fixed arrays), and never frees and reallocates.
- Departure from TigerStyle: where an input has no natural bound (an image's file count, a registry blob's size), stream it through fixed buffers, and bound what must be held in memory at once (for example, entries per directory). If a design seems to need unbounded memory, stop and write it up for review.

#### Functions and names

- **At most 70 lines per function, 100 columns per line**, 4-space indentation, `zig fmt`.
- Push `if`s up and `for`s down. A parent function keeps the control flow and the state; leaf functions are pure and compute what should change.
- Smallest possible scope; no variable before it is needed. Do not copy or alias state.
- `snake_case` for files, functions and variables. No abbreviations (`source`/`target`, not `src`/`dst`). Put units and qualifiers last: `size_bytes_max`, `timeout_ms`.
- Use an options struct when two arguments could be swapped. Pass library options explicitly at the call site rather than relying on defaults.
- Pass arguments over 16 bytes as `*const`. Initialise large structs in place through an out pointer.
- Split compound conditions into nested `if`/`else`. State invariants positively (`if (index < count)`). Exception: test code, reference oracles in fuzzers, and build-host tooling (`tidy`, `size_check`) may use compound conditions in branches, because an oracle that mirrors the production code's structure stops being independent. Compound *assertions* are banned everywhere.
- Make the rounding intent of every division explicit (`@divExact`, `@divFloor`, `std.math.divCeil`).
- Handle every error. `catch unreachable` is allowed only with an assertion-grade comment explaining why the error cannot occur. `zig build tidy` requires that comment on the same line or the line directly above, and rejects `and`/`or` inside `assert(...)`.
- Comments say **why** and are full sentences. Each test opens with a comment giving its goal and method.
- Commit messages explain why. A PR description is not a commit message.

#### Dependencies and tooling

- **No dependencies** beyond the Zig toolchain. External programs are allowed only where the spec names them as part of the system: `newuidmap`/`newgidmap`, `pasta`, and QEMU for the test VM.
- Build, tidy, fuzz and VM tooling are written in Zig, not shell. A `.sh` file needs a written reason.

### Testing

A fuzzer or simulator proves only that bugs are present, never that they are absent. So: build a precise mental model of the code first, encode it as assertions, explain it in comments for the reviewer, and then let seeded tests try to break it.

#### Layers

1. **Unit tests**: next to the code (`test` blocks), covering valid inputs, invalid inputs, and the boundary where valid becomes invalid.
2. **Snapshot tests**: user-visible output (the `doctor` report, error lines) is compared against checked-in expected text. Error messages are part of the product.
3. **Seeded fuzzers**: `zig build fuzz -- <fuzzer> [seed]`. Every failure prints its seed and reproduces exactly from it. Without a seed, a fuzzer picks one and prints it first. CI runs every fuzzer for a fixed number of iterations on a random seed and prints the seed.
4. **Deterministic simulation**: all kernel interaction goes through one narrow interface (`src/host.zig`) with two implementations: `host_real.zig` (syscalls) and `host_sim.zig` (an in-memory model driven by a seeded PRNG). The simulator injects faults: `EINTR`, `EAGAIN`, `ENOMEM`, `EPERM`, `ENOSPC`, short reads and writes, missing files, malformed `/proc` contents, and process crashes at any step. Logic above `host.zig` must not know which implementation it is using. From M3 on, the store's simulator crashes at every write point and then asserts that the store is either unchanged or validly updated. This is Zigbox's equivalent of TigerBeetle's VOPR.
5. **VM demo tests**: `zig build demo-mN` in a real QEMU guest. Only these show that the milestone works. Layers 1–4 never stand in for them.

#### Rules

- Test the negative space as hard as the positive: every failure path in a demo script has a test, and every operating error has a test that triggers it.
- No test depends on wall-clock time, host state or test order. Randomness comes only from a seed.
- A bug found by any layer first gets a regression test, normally a fixed seed or a fixture, and only then a fix.
