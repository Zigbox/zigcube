# The `zcube` command line

`zcube` talks to `zcube-server` over the HTTP API ([api.md](api.md)) and nothing else: it opens no
store and starts no process. Every command below was run against a real `zcube-server` on SQLite
to write this page; the end-to-end test (`src/cli_test.zig`) runs them again on every `zig build
test`. It is C0 slice 6b, which also holds the diagnostics machinery ([DIAGNOSTICS.md](../DIAGNOSTICS.md)).
It is not `demo-c0`: that needs the real agent.

```
zcube [options] apply <file.zon>        show what the file would change, then apply it
zcube [options] delete service <name>   delete a service; its replicas are stopped
zcube [options] get service [name]      services and how many replicas run
zcube [options] get replicas [service]  replicas, where they run and how they are doing
zcube [options] why <kind> <name>       why a service, replica or node is as it is
zcube [options] explain <code>          explain a diagnostic code, offline
zcube [options] bundle --last           the evidence for the last failure
zcube [options] bundle <kind> <name>    the evidence for a service, replica or node
zcube help | version
```

| Option | Meaning |
| --- | --- |
| `-v`, `--verbose` | the full cause chain and context of a failure; every request made, with its id |
| `-o`, `--output text\|wide\|json` | `wide` adds columns to `get`; `json` is for scripts (below) |
| `--server HOST:PORT` | where `zcube-server` listens: this flag, else `$ZCUBE_SERVER`, else `127.0.0.1:7070`. An IP address (or `localhost`) and a port |
| `-y`, `--yes` | `apply`, `delete`: do not ask first |
| `--dry-run` | `apply`: show the change and stop |
| `--no-redact` | `bundle`: keep secrets in the bundle (prints a warning) |

Options may come before or after the command. `--` ends them. Anything else that starts with `-`
is `ZC-E0111`.

## apply and delete

`zcube apply hello.zon` parses the file, asks the server what applying it would change
(`POST /v1/apply?dry_run=1`), prints that, asks, and only then writes (`POST /v1/apply`):

```
$ zcube apply hello.zon
service hello: would update
  replicas 3 → 5
apply? [y/N] y
applied service hello: replicas 3 → 5
```

- A file that is already what is stored prints `service hello: unchanged` and asks nothing.
- `--yes` skips the question. **Without a terminal on standard input and without `--yes` it fails
  with `ZC-E0113`; it never waits and never guesses.** An answer that is not `y` or `yes` (or the end
  of the input) is `ZC-E0114`. `--dry-run` shows the change and stops.
- The service file is HANDOFF's example: `.name`, `.image`, `.replicas`, `.command`, and optionally
  `.env` (pairs of strings) and `.limits` (`.cpu_millis`, `.memory_bytes`). An unknown field is an
  error, so a typo is not silently ignored. Every problem is `ZC-E0110` with the file, line and
  column and the line itself (`--verbose`); a file that can't be read is `ZC-E0109`. Nothing is
  sent before the file is valid.
- The change is recorded as `user@host` (`$USER` and the host name); the server does not check it
  (writes are unauthenticated until auth exists, [api.md](api.md)).
- `zcube delete service hello` says what is running (`2/2 running; its replicas will be stopped`),
  asks the same way, and calls `DELETE /v1/services/hello`. It is not in the brief's command list;
  the approved write endpoint needs a caller, and the end-to-end test needs to delete.

## get

```
$ zcube get service
NAME   READY  IMAGE
hello  3/3    b3:51aa9c03

$ zcube get replicas hello -o wide
REPLICA  SERVICE  NODE   STATUS   AGE  GEN  IMAGE        DETAIL
hello-1  hello    node1  running  12s  1    b3:51aa9c03
hello-2  hello    node1  running  12s  1    b3:51aa9c03
hello-3  hello    node1  running  12s  1    b3:51aa9c03
```

`READY` is running replicas over desired. `STATUS` is the agent's report: `running`, `starting`,
`exited`, `killed`, `oom`, `pid-limit`, `start-failed`, `lost`, or `pending` (no report yet). `DETAIL`
is the diagnostic of a failed start (`ZBX-E0501: image not found`) or how it exited. `AGE` is
measured against the server's clock, not the laptop's. The command reads `/services/`, `/replicas/`
and `/observed/` with `GET /v1/list` and joins them (docs/keys.md is the contract).

## why

`zcube why service broken` prints the server's chain, word for word (`state.text`, then `←` and
each step's `text`); a step that carries a diagnostic is the full diagnostic block under its arrow.
With a service that is running and no agent:

```
$ zcube why service hello
service hello: 0/3 running
  ← service hello wants 3 replicas and 0 exist
  ← service hello was applied by alex@vm (request zc-1a17d73d194-eef1d8de-2): generation 1, 3 replicas
```

With a digest that is not in the node's store (this is the end-to-end test's expected output):

```
service broken: 0/1 running
  ← replica broken-1 failed to start on node1; it was not replaced because a new one would fail the same way
  ← error[ZBX-E0501]: image not found
      cause  digest b3:00ff7be1 is not in this node's store
      fix    check the digest in the service file, or pull the image first
      more   zbx explain E0501 · rerun with --verbose for the full cause chain
      docs   https://zigbox.github.io/zigbox/errors/E0501.html
```

`--verbose` adds each decision's id, actor and action, and the full cause chain of a diagnostic step.

## explain

`zcube explain E0201` (also `ZC-E0201`, in any letter case) prints the registry's long explanation,
offline. `ZBX-` codes come from Zigbox's registry through the linked `zigbox` module, plus the
placeholder runtime codes of [runtime-codes.md](runtime-codes.md). The same text is generated into
`site/errors/<code>.html`, the `docs` link of every `ZC-` diagnostic. An unknown code is `ZC-E0118`.

## Output modes and exit codes

| Mode | Standard output | Standard error |
| --- | --- | --- |
| default | the result | the diagnostic: summary, innermost cause, fixes, `more` and `docs` |
| `--verbose` | the result | plus the cause chain, context (`server`, `reqid`, ...) and one line per request |
| `--output json` | the result as JSON | one JSON object per diagnostic, one per line |

Exit codes follow DIAGNOSTICS.md and the blame of the **first** diagnostic: `0` ok, `1` your input,
`2` your environment, `3` an external service (the store), `70` a bug. A warning (`ZC-W0119`) does not
change the exit code.

JSON on standard output, for `--output json`:

| Command | Shape |
| --- | --- |
| `get service` | `{"kind":"service","items":[{"name","image","desired","running","generation","applied_by","command"}]}` |
| `get replicas` | `{"kind":"replicas","items":[{"id","service","node","generation","image","status","detail","started_at_ms"}]}` |
| `why` | the server's body of `GET /v1/why`, unchanged |
| `apply`, `delete` | the server's answer (`action`, `change`, `revision`, `decision`, ...), unchanged |
| `explain` | `{"code","severity","blame","summary","explanation","exit_code"}` |
| `bundle` | `{"path","redacted","manifest"}` |

JSON mode never prompts: `apply` and `delete` need `--yes`, unless standard input is a terminal, in
which case the question is the one line of standard error that is not JSON.

### A server that is not there

```
$ zcube get service
error[ZC-E0102]: can't reach zcube-server
  cause  connection refused: nothing is listening there
  fix    start it:                          zcube-server --store sqlite:zcube.db --create-store
         or name the one that is running:   zcube --server HOST:PORT get service
  more   zcube explain E0102 · rerun with --verbose for the full cause chain
  docs   https://zigbox.github.io/zigcube/errors/E0102.html
```

`--verbose` adds `while sending a request to zcube-server`, the second cause (`no answer from
zcube-server at 127.0.0.1:7070`) and the context `server` and `reqid`. A reply that is not what the
API promises is `ZC-E0103`. When the *store* is down, the server answers 503 and the diagnostic is
the server's own (`ZC-E0201`), shown unchanged.

## Request ids

Every request carries an `X-Request-Id` (`zc-<time>-<random>-<n>`), which the server uses as its
own. `--verbose` prints each request's id, method, path and status on standard error; a failed
request's id is the `reqid` context of its diagnostic (`--verbose`, JSON) and `request id` in the
bundle's `command.txt`, so a CLI error can be matched to the server's log.

## Bundles

`zcube bundle --last` (or `<kind> <name>`) writes one `.tar.gz` in
`$XDG_STATE_HOME/zcube/bundles/` (else `$HOME/.local/state/zcube/bundles/`, mode `0600`, written
under a temporary name and renamed) and prints its path and its manifest. **It never leaves the
machine.** Files sit under one directory named like the bundle (`<UTC time>-<label>`):

| File | What |
| --- | --- |
| `MANIFEST.txt` | every file and why; what was cut at a bound; how many values were redacted |
| `command.txt` | the command, the server, the request id |
| `diagnostic.json` | the diagnostics, as `--output json` prints them (for `--last`) |
| `version.txt`, `uname.txt`, `os-release.txt` | zcube's version and build, kernel release and machine (not the host name), distribution |
| `environment.txt` | the names of the environment variables; every value is `[redacted:env]` |
| `status.json` | `GET /v1/status` |
| `why.json` | `GET /v1/why/<kind>/<name>`: the decision chain |
| `keys/*.json` | the store keys of the subject (`GET /v1/list`), **at the failing revision** when it is known and still there, else now (the manifest says which) |

The evidence from the server is best effort: a server that is down is the usual reason to want a
bundle, so each piece that can't be had is a `<name>.unavailable.txt` holding the diagnostic that
says why. Files are cut at 128 KiB and the manifest says so.

**Redaction** is on by default and `--no-redact` prints `ZC-W0119`. Four layers:

1. every environment value is `[redacted:env]` (the names stay);
2. the values of secret-named environment variables of the `zcube` process are removed wherever
   they appear in any file;
3. every `env` value in a store record (`keys/*.json`) is replaced, whatever its name
   (`bundle_redact.zig`, `redact_env_values`);
4. Zigbox's redactor, ported: private keys, well-known token shapes, `Bearer` and `Authorization`,
   and `NAME=value`, `--name value` and JSON/ZON pairs for names containing `token`, `secret`,
   `password`, `passwd`, `passphrase`, `credential` or ending in `key`.

It is a net, not a proof (an innocent-named secret in a free-text field can pass), which is why the
manifest says to read every file before sharing.

**A `bug` diagnostic writes a bundle by itself**, also when the server reported the bug; the path
is the diagnostic's `saved` line. A panic does not (a panic handler that wrote one could panic).

**The last failure** is remembered in `$XDG_STATE_HOME/zcube/last-failure.json` (the diagnostics,
the command, the server, the request id, the subject and the revision when the answer had one) by
every failing command except `bundle` and the ones that need no server. That is what `--last`
reads; with none it is `ZC-E0117`.

## Codes the command line raises

`ZC-E0101` to `E0108` are documented in [api.md](api.md); the command line raises `E0101` (a service
that does not exist), `E0102`, `E0103` and relays the rest from the server.

| Code | Blame | Summary |
| --- | --- | --- |
| `ZC-E0109` | user | the service file can't be read |
| `ZC-E0110` | user | the service file isn't valid |
| `ZC-E0111` | user | the command line can't be understood |
| `ZC-E0112` | user | the server address can't be used |
| `ZC-E0113` | user | apply needs an answer and there is no terminal |
| `ZC-E0114` | user | the apply was declined |
| `ZC-E0115` | environment | can't write the output |
| `ZC-E0116` | environment | can't use the state directory |
| `ZC-E0117` | user | there is no failure to bundle |
| `ZC-E0118` | user | no such diagnostic code |
| `ZC-W0119` | (warning) | `--no-redact` keeps secrets in the bundle |
| `ZC-E0120` | environment | zcube ran out of memory |
| `ZC-B0002` | internal | zcube failed in a way it should not (a command failed and said nothing) |

## How it is tested

- **Golden tests** (`src/cli_golden.zig`, `src/testdata/cli/`): every registered `ZC-` code has its
  default, verbose and JSON output checked in. The files are embedded at compile time, so a code
  without its three files does not compile, and a test fails if a code has no case. A *raised* case
  runs the real command line; a *relayed* case is a canned server reply, so it pins how the command
  line shows a diagnostic that the server, the store or the runtime raises (those conditions are
  tested where they are raised). Changing a message: `ZCUBE_GOLDEN_UPDATE=$PWD/src/testdata/cli zig
  build test` rewrites the files, and the diff is the review.
- **No stack trace** (same file): every case in every mode, both streams, must show no trace,
  source location, address or raw Zig error name.
- **Bundle redaction** (`src/cli_test.zig`): fake secrets in the environment and in a service's
  `env` must not appear in any file of the bundle; `--no-redact` must keep them and warn.
  `src/bundle_redact_fuzz.zig` plants secrets in the shapes the redactor claims to cover (a port of
  Zigbox's fuzzer); a failure prints the seed, and `ZCUBE_FUZZ_SEED=<n>` replays it.
- **End to end** (`src/cli_test.zig`): a live server on SQLite, a simulated agent, and the command
  line in-process: apply, get, why, scale, delete, a declined apply, a dry run, JSON output, an
  unreachable server, bundles.

## Known gaps

- **No connect timeout.** The standard library's `connect` does not implement one yet (it panics
  when given one), so a host that silently drops packets keeps `zcube` waiting until the kernel gives
  up. A refused connection is immediate, and a server that accepts and then says nothing is
  `ZC-E0102` after 30 s without a byte (`poll` on the socket; a receive timeout on the socket makes
  the standard library's reader panic, so `cli_http.zig` reads the socket itself).
- Two bundles with the same label in the same second overwrite each other.
- `apply` shows the plan, then asks, then writes; if someone else changed the service in between,
  the write is planned again (up to three times, [api.md](api.md)) and the *applied* line is the final
  change, which may differ from the plan that was shown.
- The reply is read by its `Content-Length`, and `zcube` closes the connection first (it sends no
  `Connection: close`): whoever closes first keeps the connection in `TIME_WAIT` on its port for a
  minute, and a server on that port cannot be restarted meanwhile (docs/core.md). A reply with no
  length is read to the end of the connection; a chunked reply is `ZC-E0103`. The server never
  sends either.
