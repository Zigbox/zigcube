# Diagnostics standard

Shared by Zigbox and Zigcube. The canonical copy lives in `Zigbox/zigbox`; `Zigbox/zigcube` carries an identical copy. Change both together.

When something goes wrong, the user should see a short, designed explanation: what failed, why, and what to do next. More detail is available on request, and a complete evidence bundle can be produced when needed. A stack trace is never what a user sees for a problem they caused or can fix.

## Principles

1. **Every user-facing failure is a diagnostic, not an error tag.** It has a stable code, a one-line summary, the cause, and at least one concrete next step.
2. **Layered detail.** The default is a few lines. `--verbose` adds the full cause chain and context. A bundle adds everything else. Nobody has to read past the layer they need.
3. **Blame correctly.** A diagnostic says whether the problem is the user's input, the host or environment, an external service (a registry, the store), or a bug in our code. Only the last one asks for a bug report.
4. **Name the real cause, not the last symptom.** "Permission denied" is a symptom. "AppArmor restricts unprivileged user namespaces on this host" is a cause.
5. **Fixes are runnable.** Where a fix is a command, print the command.
6. **Same model everywhere.** CLI output, JSON output, the Zigcube API, and `zcube why` all render the same diagnostic structure. A failure on a remote node looks the same as a local one.
7. **Diagnostics are tested.** Their text is part of the product and has golden tests like any other output.

## Anatomy

Default rendering:

```
error[ZBX-E0101]: can't create a user namespace
  cause  this host restricts unprivileged user namespaces through AppArmor
         (kernel.apparmor_restrict_unprivileged_userns = 1)
  fix    allow zbx only:   sudo zbx doctor --fix apparmor
         or system-wide:   sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
  more   zbx explain E0101 · rerun with --verbose for the full cause chain
  docs   https://zigbox.github.io/zigbox/errors/E0101.html
```

With `--verbose`, the same diagnostic adds the cause chain (each layer that wrapped the failure, outermost first) and context fields:

```
error[ZBX-E0101]: can't create a user namespace
  while  starting container web-1 (image alpine:3.20, b3:7f1c…a02e)
  while  setting up namespaces for pid 41822
  cause  clone3(CLONE_NEWUSER) returned EACCES
  cause  AppArmor restricts unprivileged user namespaces
         (kernel.apparmor_restrict_unprivileged_userns = 1)
  host   Ubuntu 24.04, kernel 6.8.0-45, zbx 0.1.0 (b3:91e0…)
  fix    …
```

An internal bug (an invariant we broke, an unexpected error from our own code, a panic) renders differently:

```
bug[ZBX-B0001]: zbx hit an internal error while committing a container
  this is a bug in zbx, not something you did
  saved  diagnostic bundle: /home/alex/.local/state/zbx/bundles/2026-10-23T22-41-07Z.tar.gz
  report https://github.com/Zigbox/zigbox/issues/new (attach the bundle after reviewing it)
```

A bug's internal message (the panic text or the broken invariant) means nothing to the user, so the default output leaves it out. `--verbose` shows it as the bug's `cause` line, and JSON carries it in `causes`.

### Fields

| Field | Required | Meaning |
| --- | --- | --- |
| `code` | yes | Stable identifier, e.g. `ZBX-E0101`. Never reused or renumbered. |
| `severity` | yes | `error`, `warning`, `note`, or `bug`. |
| `blame` | yes | `user`, `environment`, `external`, or `internal`. |
| `summary` | yes | One line, present tense, no trailing period, under about 70 characters. |
| `causes` | yes, at least one | The cause chain, innermost real cause last. |
| `while` | no | What was being done when it failed (the `while` lines), outermost first. JSON always carries the array, empty if there are none. |
| `context` | no | Key–value pairs (container, image, digest, node, pid, path). |
| `fixes` | yes unless `internal` | Each fix is a sentence and optionally a command. |
| `docs` | automatic | Generated from the code (see Codes). |
| `omitted` | automatic | How many causes, `while` lines, context pairs and fixes were dropped because they exceeded the collector's fixed bounds. Verbose output says "(N more not shown)"; JSON always carries the counts, zero included. |
| `saved` | bug only | The absolute path of the bundle written for this bug. JSON key `saved`, absent when no bundle was written. |
| `trace` | bundle only | Zig error return trace and stack, never in default or verbose output. |

## Codes

- Prefix by product: `ZBX-` for Zigbox, `ZC-` for Zigcube.
- Letter by kind: `E` error, `W` warning, `B` internal bug.
- Four digits, grouped by subsystem. Zigbox: `00xx` CLI and general, `01xx` host and doctor, `02xx` runtime and isolation, `03xx` limits, `04xx` store, `05xx` registry and pull, `06xx` network, `07xx` state, `08xx` build, `09xx` trust and policy. Zigcube: `01xx` API and CLI, `02xx` store backends, `03xx` controllers, `04xx` scheduler, `05xx` agent, `06xx` distribution, `07xx` mesh, `08xx` trust.
- Every code is declared once in a registry (`src/diag/codes.zig`) with its summary template, blame, and a long explanation. The build fails if a code is used but not registered, registered twice, or registered without an explanation.
- `zbx explain <code>` and `zcube explain <code>` print the long explanation offline. The same text is generated into `site/errors/<code>.html`, which is the `docs` link.

## Output modes

| Mode | Flag | Shows |
| --- | --- | --- |
| Default | none | summary, innermost cause, fixes, `more` and `docs` lines |
| Verbose | `-v`, `--verbose` | plus the full cause chain and context fields |
| JSON | `--output json` | the full diagnostic object on stderr, one JSON object per line, for scripts and CI |
| Bundle | `zbx bundle`, `zcube bundle`, or automatic on `bug` | everything below |

A command may report several diagnostics (`zbx doctor` reports one per failing check). They come in order: in text, blocks are separated by a blank line; in JSON, each is one object per line. The exit code is decided by the blame of the diagnostics.

Exit codes: `1` user, `2` environment, `3` external, `70` internal (EX_SOFTWARE).

A command that runs a container (`zbx run`, and later anything that waits on a workload) passes the container's own exit code through unchanged, so it cannot also use those four: a container can exit with any code. Such a command uses the shell's reserved codes for its own failures instead, as Docker and Podman do:

| Code | Meaning |
| --- | --- |
| `125` | zbx itself failed before the command started (any blame: a bad flag, a missing rootfs, a refused namespace, a bug) |
| `126` | the command was found but could not be run (not executable, wrong CPU) |
| `127` | the command was not found |
| `128`+*n* | the container's process was killed by signal *n* |
| anything else | the container's own exit code |

A container that itself exits 125 to 127 is the one ambiguous case; the diagnostic on stderr, or the JSON on `--output json` (the run's last line carries `container_exit` only when the container ran), tells them apart.

Colour only when stderr is a terminal and `NO_COLOR` is unset. Output must read correctly with no colour at all.

## Bundles: the kitchen sink, only when needed

A bundle is a single `.tar.gz` file with everything needed to diagnose a failure without a back-and-forth. (gzip, because the Zig standard library can write it; it decompresses zstd but cannot compress it.)

- **Created** automatically for every `bug` diagnostic, and on request with `zbx bundle [--last | <container>]` or `zcube bundle [--last | <kind> <name>]`.
- **Contents:** a `MANIFEST.txt` listing every file and why it is there; the diagnostic in JSON; versions; `zbx doctor` output; kernel, distro and cgroup layout; the subject's record (for Zigbox, the run record); the environment's variable names. Added as the subsystem that produces them exists: the error return trace and stack, build digests, the relevant config (redacted), recent events and logs for the subject; for Zigcube, the `zcube why` decision chain and the relevant store keys at the failing revision. All files sit under one directory named like the bundle file.
- **Redaction by default:** every environment value (the names stay, so the bundle shows what was set), secret mounts, tokens, registry credentials and anything matching known secret patterns are replaced with `[redacted:<kind>]`. `--no-redact` exists but prints a warning.
- **Local only.** Bundles are written to the user's state directory and never uploaded. The user reviews the manifest before sharing.
- **Bounded size:** logs are tail-limited; the manifest notes anything truncated.

## Implementation in Zig

Zig error sets carry no payload, so context travels separately:

- Any function that can fail across a module boundary takes a `*Diag` (a per-operation collector) and returns a plain Zig error. The error says *that* it failed; the `Diag` says *why*.
- Inner layers add causes with `diag.cause(...)`; outer layers add context with `diag.while_(...)`. Nobody formats text for the user below the CLI or API boundary.
- At the boundary, the CLI renders the `Diag` according to the output mode; the Zigcube API serializes it to JSON, and the CLI on the other side renders it identically.
- `std.debug` error return traces are captured into the `Diag` for bundles, never printed directly.
- A panic handler turns panics into a `bug` diagnostic. A bug raised as a diagnostic (an invariant check, an unexpected error from our own code) also writes an automatic bundle; a panic does not, because writing one from a panic handler could panic again.
- Syscall failures are translated once, in one place, into causes with the syscall name, errno, and a human explanation, plus host facts that explain the errno when known (AppArmor, missing subuid range, cgroup delegation).

## Zigcube specifics

- Agent failures are recorded as diagnostics on the observed-state key, and every controller decision references the diagnostic that caused it. `zcube why` walks that chain and renders each step with the same anatomy.
- Every API request gets a request ID, printed in `--verbose` output and included in bundles, so a CLI error can be matched to server and agent logs.

## Testing

- **Golden tests** for every registered code: a test triggers the condition and compares default, verbose and JSON output against checked-in files. Changing a message means updating the golden file in the same commit.
- **Demo assertions:** every refusal in a milestone demo script asserts the code and summary, not just a non-zero exit.
- **No stack traces for users:** a CI test runs the failure cases and fails if any default or verbose output contains a stack trace or a raw Zig error name such as `error.AccessDenied`.
- **Bundle check:** a CI test creates a bundle with fake secrets in the environment and fails if any appear unredacted.

## Review checklist

Before merging a change that adds or touches a failure path:

- [ ] Is there a registered code, with blame set correctly?
- [ ] Does the default output fit in a few lines and name the real cause?
- [ ] Is there a runnable fix, or a clear statement that this is our bug?
- [ ] Is there a golden test?
