# Restart orders: from C0 on a fake runtime to C1 with local mode

These orders restart Zigcube after a pause in which Zigbox shipped M3 to M6, M4b (macOS) and is building M6b. They supersede `HANDOFF.md` where the two disagree; `HANDOFF.md` stays the reference for everything they do not change. The design is Part II of Zigbox's `docs/SPEC.md` (live doc rev 76), which wins over both. The owner decided the points marked **Decided** on 2026-10-30; the rest is the plan they asked for.

## What changed while Zigcube waited

- **C0 is demonstrated against `FakeRuntime` only.** Real Zigbox has never run under Zigcube.
- **The pinned Zigbox is about M2** (`90b6f1c`, 281 commits behind Zigbox's `main` on 2026-10-30). Since then Zigbox has the store (M3), pull and `zbx.lock` (M4), per-container networks with `--net none|host|user` and `--publish` (M5), named state volumes, `--tmpfs`, `--bind`, `--secret` and `-e` (M6), and a macOS `zbx` that drives a small Linux machine (M4b). M6b (writable project mounts, `--user`, `zbx logs`, `zbx exec`) is being built.
- **Zigcube is now the local-dev story.** **Decided:** zbx has no Compose equivalent; to run more than one service, even on one laptop, a developer installs the Zigcube server. **Decided:** C1 includes that local mode (spec rev 76): zcube-server on SQLite with one agent on the same machine, one command to start, Linux and macOS, services reaching each other by name where the file grants it (a single-node form of C4, no WireGuard).
- **Diagnostics moved on.** Zigbox's `DIAGNOSTICS.md` (canonical) now says fixes carry `needs_root` and `template` flags, documents `zbx doctor --output json`, and adds the `10xx` macOS group. Zigcube's copy is behind, and PR #10 (the switch from the placeholder `ZBX-E0501` to Zigbox's `ZBX-E0410`) conflicts with `main`, which has since added about 25 uses of the placeholder.
- **Zigbox's process got faster**, and the same changes apply here (below).

## The order of work

1. **R1 · Re-pin and the contract.** Pin Zigbox at the merge of its M6b, which brings logs, exec and pull in the library (or, if M6b is not merged when you start, at its `main` and again at M6b). Revise the `Runtime` contract to what the library offers, as drafted below. **Decided: the owner reviews the revised contract before anything is built on it** (it is an **Ask first** item in `HANDOFF.md`). Copy Zigbox's `DIAGNOSTICS.md` over Zigcube's, redo the `E0410` switch on current `main`, and close PR #10 in favour of that.
2. **R2 · C0 on the real runtime.** A `ZigboxRuntime` beside `FakeRuntime`, the agent able to use either, and `demo-c0` passing on real Zigbox in a VM (Ubuntu 24.04, as Zigbox's demos run), with `FakeRuntime` kept for the simulator and the fast tests. Every C0 acceptance criterion holds on the real runtime: re-adoption after an agent restart, no duplicates, `why` chains ending in Zigbox's real diagnostics.
3. **C1 · Fleet, with local mode.** Write C1's brief from the spec's C1 (rev 76), with local mode as its own slices. Its new demo step: on a laptop, local mode started by one command, a file with an app and postgres, the app granted `db:5432`, data reaching the app by the name `db`, and without the grant a refused connection that `zcube why` explains.

## The `Runtime` contract, revised (draft for the owner's review)

The shape stays: Zigbox's library already implements `start`, `stop`, `inspect`, `list` with re-adoption, and an event stream (`Watcher`), with the same `ExitReason` and `Status`. What grows is what a `Spec` can say, and three operations.

```zig
pub const Spec = struct {
    image: []const u8,                 // tree digest, "b3:…"; resolved and pulled beforehand (ensure_image)
    name: []const u8,                  // the container's name and hostname: the replica id
    command: []const []const u8,       // empty: the image's own entrypoint and command
    env: []const [2][]const u8,        // values reach the container and are never stored by Zigbox
    workdir: ?[]const u8 = null,
    user: ?[]const u8 = null,          // USER[:GROUP], resolved in the image (M6b)
    limits: struct { cpu_millis: ?u32 = null, memory_bytes: ?u64 = null, pids: ?u32 = null },
    network: enum { none, host, user } = .none,
    publish: []const struct { host: u16, container: u16 } = &.{},
    state: []const struct { volume: []const u8, path: []const u8, read_only: bool = false } = &.{},
    mounts: []const Mount = &.{},      // tmpfs, read-only bind, secret; writable project mounts are a
                                       // developer's, not the agent's (M6b), and are not offered here
    labels: []const [2][]const u8,     // must include zcube.replica=<id> for re-adoption
};

// Unchanged: ExitReason { exited, signaled, oom, pid_limit, start_failed: Diagnostic, lost },
// Status { starting, running, stopped: ExitReason }, start, stop(grace_ms), inspect, list, events.
// New:
//   ensure_image(reference) -> tree digest   pull and pin; needs pull in Zigbox's library (below)
//   logs(handle, options) -> reader          after Zigbox M6b: bounded, framed, follow
//   exec(handle, spec) -> exit                after Zigbox M6b: joins the container, gains nothing
```

Semantics to approve:

- **No network unless the service asks.** A service gets `network = .none` unless its file grants something; local mode's services-by-name (C1) and C4 build on Zigbox's per-container network namespaces, never on `host`.
- **State volumes are Zigbox's,** placed by the scheduler later (C7); in C1 a volume lives on the node that made it, and a service using one is not moved off that node.
- **Environment values are the agent's to hold, Zigbox's never to store,** as Zigbox's `-e` rule says. The agent endpoints already carry values; nothing else Zigcube writes (decision records, bundles, logs) may.
- **Writable host mounts are not part of the contract.** They are a developer's tool in `zbx`; a cluster service gets state volumes.

## What Zigcube needs from Zigbox

- **Pull in the library.** Today Zigbox's pull lives in its CLI's code; the `zigbox` module cannot fetch an image, and `ensure_image` needs it. **Decided:** it comes with Zigbox M6b (its slice 4), so re-pinning at M6b's merge brings it. If R2 starts before that, it may shell out to `zbx pull` and read its `--output json`, as a stated and temporary cut, removed at the re-pin.
- **Logs and exec** come with Zigbox M6b, in the library.
- **The re-pin itself**: Zigbox's `zigbox` module at a merged commit, fetched as a package as today.

## How the work is run (what sped up Zigbox)

- **A `REVIEW.md`** checklist the implementer runs on its own diff before reporting: Zigbox's items that apply (schemas only grow, records stay readable by later releases, parse accepts only what render writes, a test fills memory before checking it was written, every exit path tested, every bound named) and Zigcube's own (store conformance on every backend, the core `wasm32-freestanding`-clean, controllers idempotent and level-triggered, a decision record for every action).
- **One gate, `zig build check`**, ending in `check: PASS <commit>`: build, tests, tidy, the wasm checks, every fuzzer with a fresh seed, every demo harness compiled, and the tests again as an ordinary user when run as root. A report without that line, for that commit, is not a report.
- **LLVM for Debug builds** (`use_llvm = true` on the executables and tests): Zig's own x86_64 backend writes every `undefined` global into the binary, which made Zigbox's test binaries 1.4 GB each and filled the session's disk.
- **VM checks on CI's KVM runners, from scratch branches** (`vm/<demo>-<slug>`) that a workflow runs and then deletes, instead of slow emulation in the cloud container.
- **One implementer at a time unless slices are independent by file, each worktree with its own `ZIG_GLOBAL_CACHE_DIR`; Opus for the risky slices** (the runtime switch, local mode's networking), Sonnet for the rest.
- **An agent test in every demo**: a scripted agent drives the demo through `zcube`'s JSON alone; anything it must scrape from text is a finding, fixed or recorded.

## The Mac

zcube-server and the CLI need no containers and can run natively on macOS; the agent needs Linux, so on a Mac it runs inside the zbx machine, talking to the server across the machine's boundary. Propose how (the agent as a Linux binary in the guest started by the macOS `zbx`, and the server reached over the forwarded loopback or vsock) in C1's brief, so that local mode is not Linux-only by accident. Ask first.

## Ask first (added to `HANDOFF.md`'s list)

- The revised `Runtime` contract, before R2 builds on it.
- How local mode runs on the Mac.
- Any dependency on a Zigbox change that is not merged (M6b's pull, logs and exec, until it merges).
