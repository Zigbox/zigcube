# Proposal for Zigbox: let a second product's diagnostics plug into `src/diag/`

For the owner of `Zigbox/zigbox`. Self-contained: it needs no other Zigcube document. It is
option D of `docs/diagnostics-plan.md`, which the Zigcube owner accepted on 2026-10-26 ("we will
absolutely need a way to add Zigcube's errors to Zigbox's"). Read against Zigbox `main` at
`19984dc`: `src/diag/{codes,diag,render,explain}.zig`, `src/constants.zig`, `src/zigbox.zig`.

## The problem in one paragraph

Zigcube's agent links the `zigbox` module. A start that fails on a node arrives as a Zigbox
`Diag` carrying a `ZBX-` code. It must travel through the Zigcube API as JSON, and `zcube why`
must render it, next to Zigcube's own `ZC-` diagnostics, with the same anatomy. Today that
cannot be done without a change in Zigbox, because (1) `Diag.code` is `?codes.Code`, a closed
`enum(u8)` of `ZBX-` tags; (2) `render.render` takes a `*const Diag`, and the renderer hard-codes
`ZBX-` (`codes.full_name(code)[4..]`), `zbx explain`, `zbx bundle`, "this is a bug in zbx", the
report URL and the docs base; (3) there is no parser for the JSON form, and a diagnostic that
has been through the wire is not a `Diag` any more.

## What stays as it is

The collector. `Diag`, `codes.Code`, `codes.registry`, `codes.full_name`, `explain.render` and
`render.render(diag, mode, color, buffer)` keep their names, signatures and behaviour. Every
existing call site and every golden test is untouched. This is purely additive, and it is
independent of Zigbox's M2.

## What to add

### 1. `src/diag/diagnostic.zig`: a finished diagnostic as plain data

```zig
pub const Diagnostic = struct {
    code: Bounded(constants.diag_code_bytes), // "ZBX-E0501", "ZC-E0201": text, not an enum
    severity: codes.Severity,
    blame: codes.Blame,
    summary: Bounded(constants.diag_summary_bytes),
    causes: diag.Causes,
    whiles: diag.Whiles,
    pairs: diag.Pairs,
    fixes: diag.Fixes,
    saved: Bounded(constants.bundle_path_bytes), // empty unless a bug wrote a bundle
    command_missing: bool,                       // as in Diag, for the container-run exit codes
};

/// Copies a finished collector. Initialises `out` in place (it is several kilobytes).
pub fn from_diag(out: *Diagnostic, d: *const Diag) void;

/// One JSON object on one line: the exact bytes `render` already writes in `.json` mode.
pub fn write_json(writer: *std.Io.Writer, diagnostic: *const Diagnostic) std.Io.Writer.Error!void;

/// The inverse of `write_json`. Bounded: a field over its bound, an unknown severity or blame,
/// or a list over its capacity is `error.Malformed`, never a truncation. Initialises `out`.
pub fn parse_json(out: *Diagnostic, bytes: []const u8) error{Malformed}!void;
```

`Diagnostic.exit_code` follows from `blame` alone (`codes.exit_code(blame)`; the container-run
scope needs only `command_missing` and the code's `can_end_run`, which the owner of the product
passes in). The bounds are the existing `constants.diag_*` values; the code width stays
`diag_code_bytes = 9` ("ZBX-E0501" is the longest on the wire, "ZC-E0201" fits).

`write_json` is today's private `render.write_json`, rewritten to read a `Diagnostic` instead of
a `Diag`; `render`'s `.json` mode then calls it through `from_diag`. A round-trip test
(`parse_json(write_json(x)) == x`) over every registered code is the acceptance test.

### 2. `src/diag/product.zig`: the strings that are product-specific

```zig
pub const Product = struct {
    prefix: []const u8,        // "ZBX-"  (at most 4 bytes, so the code fits diag_code_bytes)
    command: []const u8,       // "zbx": the `more` hint is "<command> explain E0101"
    bundle_hint: []const u8,   // "zbx bundle --last"
    report_url: []const u8,    // where a bug is reported
    docs_url_base: []const u8, // "https://zigbox.github.io/zigbox/errors/"

    pub const zbx: Product = .{ ... }; // today's strings, moved here

    /// The product whose prefix starts `code_text`, or null (a code from a newer version).
    pub fn find(products: []const Product, code_text: []const u8) ?*const Product;
};
```

Zigbox defines the type and `Product.zbx` only. **It does not define Zigcube's value**; Zigcube
declares its own `Product` (`"ZC-"`, `zcube`, `zcube bundle --last`,
`https://github.com/Zigbox/zigcube/issues/new`, its docs base), so Zigbox never ships another
product's strings and a change to them needs no Zigbox release. `constants.zig` gains a comptime
proof that the longest allowed `Product` strings keep `output_bytes_max` and `docs_url_bytes_max`
valid, like the proofs there today.

### 3. `render`: render a `Diagnostic` for a set of known products

```zig
pub fn render_diagnostic(
    diagnostic: *const Diagnostic,
    products: []const Product,
    mode: Mode,
    color: bool,
    buffer: []u8,
) []const u8;
```

The text and verbose layouts are today's `write_text`, reading from the `Diagnostic` and the
`Product` that `Product.find` picks **by the diagnostic's own code prefix**. That is deliberate:
`zcube why` renders a `ZBX-E0501` that came off a node, and its `more` line should read
`zbx explain E0501` (a command that exists, on the node), not a `zcube` command for a code
`zcube` did not define. A `ZC-` diagnostic gets `zcube explain ...` and its own docs and
report URLs. If no product matches (a code from a newer version), the `more` and `docs` lines
are omitted, and nothing else changes. The old entry point becomes

```zig
pub fn render(diag: *const Diag, mode: Mode, color: bool, buffer: []u8) []const u8 {
    var diagnostic: Diagnostic = undefined;
    Diagnostic.from_diag(&diagnostic, diag);
    return render_diagnostic(&diagnostic, &.{Product.zbx}, mode, color, buffer);
}
```

and **its output must be byte-identical**, which the existing golden tests already check.

### 4. `explain`: take the entry as data

`explain.render(code, buffer)` stays. Add `explain.render_entry(entry: ExplainEntry, buffer)`,
where `ExplainEntry` is `{full_name, severity, blame, summary, explanation, exit_text}` as plain
slices, and make `render` build one from the registry. Zigcube's `zcube explain` builds its own
from its registry, with no copy of the layout. (Optional; the proposal works without it, but the
two products' `explain` output would otherwise drift.)

### 5. Export the bounded building blocks (optional, removes Zigcube's copy)

Today Zigcube carries a ~330-line copy of the collector (`Text`, `Command`, `Pair`, `Fix`,
`FixOptions`, `List`, `Causes`, `Whiles`, `Pairs`, `Fixes`, `put`, `check_key`). If those are
exported from `diag/diag.zig` (they are `pub` already except `put` and `check_key`; make those
`pub`), Zigcube's `Diag` shrinks to its own registry binding on top of the same lists, and a
`Diagnostic` copy between the products becomes a plain struct copy with no conversion. Without
this step Zigcube keeps its copy and converts field by field; the proposal still works.

## What `zigbox.zig` exposes

`pub const diagnostic = @import("diag/diagnostic.zig");`, `pub const product =
@import("diag/product.zig");` next to the existing `diag`, `codes` and `render`. Nothing else.

## How Zigcube uses it

1. `build.zig.zon` gets the `zigbox` dependency, pinned by URL and hash to the commit that
   carries this change, `.lazy = true` so the server and CLI builds fetch it only when used.
2. `src/diagnostic.zig` re-exports `zigbox.diagnostic.Diagnostic`. Zigcube's `from_diag` fills
   it from Zigcube's own `Diag` (which keeps the `ZC-` registry, its build-time checks and
   `src/diag/codes.zig`). `runtime.ExitReason.start_failed` carries that type, so a runtime
   failure and a Zigcube failure are one type on the wire and in the store.
3. `src/diag.zig` (the shim) keeps its surface. Only its list types move to Zigbox's if step 5
   lands. Call sites do not change.
4. The CLI and `zcube why` render with
   `zigbox.render.render_diagnostic(&d, &.{ zigbox.product.Product.zbx, zcube_product }, ...)`.
   The API serialises with `write_json`; the CLI on the other side reads it with `parse_json`.
5. Golden tests render the same fixture diagnostics through Zigcube's path and compare bytes
   against Zigbox's own golden files for the `ZBX-` ones, so the two cannot drift.

## What Zigbox gets from it

One renderer, one JSON schema and one parser for both products; the interchange form that
DIAGNOSTICS.md already requires between node, API and CLI; no `ZC-` code and no Zigcube string
in Zigbox. Cost: about 250 lines moved or new (`diagnostic.zig` with JSON read and write,
`product.zig`, `render_diagnostic`) and a few comptime proofs; no existing signature changes.

## Open points for the Zigbox owner

- Is the JSON schema stable enough to be a wire contract? Today it is private to the renderer.
  Zigcube would version it, so a field added later must be ignorable by `parse_json`; say if you
  want an explicit `"v"` key.
- `parse_json` on untrusted input (the API takes it from agents): it is bounded, allocation
  free (a fixed buffer), and fuzzable; Zigbox's `fuzz_diag.zig` is the natural home.
- Whether `Product.find` should be a prefix match on the text (above) or on a registered list of
  prefixes; the first is simpler and is what the code text already says.

## If the answer is no

Zigcube falls back to option C: it ports the renderer (about 540 lines) in the slice that needs
it, with a cross-check test that needs the `zigbox` dependency anyway. The shim's surface is
the same either way, so no call site changes.
