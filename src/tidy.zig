//! `zig build tidy`: mechanical style rules from docs/STYLE.md that review should not have to
//! catch by eye. Ported from Zigbox's `src/tidy.zig` and adapted to Zigcube. It is a development
//! tool, not part of the shipped binaries: it runs on the build host and allocates from an arena
//! (a departure from "no allocation after startup", which governs the shipped code).
//!
//! The checks are line-oriented with a small lexer that blanks out comments and string and
//! character literals, so that text inside them never counts as code. They are heuristics tuned
//! to this codebase's formatting (`zig fmt` output), not a Zig parser. A rule that cannot be
//! decided errs towards reporting.
//!
//! Rules: 100-column lines; no tabs or trailing whitespace; functions and tests at most 70
//! lines; no `usize`/`isize` in struct or union fields; `@import` only of `std`, `builtin`,
//! `build_options`, `zigbox`, `web_files` (the embedded console), the C-library modules named
//! below, and files inside the repository;
//! no `@cImport`; no `catch unreachable` without a comment; no `and`/`or` inside an `assert(...)`;
//! snake_case function names (except functions returning `type`) and `.zig` file names; no `.sh`
//! files except those on an explicit allowlist.
//!
//! Where Zigcube departs from Zigbox's tidy: libc may be linked (docs/STYLE.md allows it in the
//! server and CLI for the Postgres and SQLite client libraries), so that rule is gone; the C
//! libraries' translated headers are importable modules; and the assertion-density average is
//! not checked yet (it needs a list of shipped files, which grows with the code; review checks
//! it meanwhile).

const std = @import("std");
const assert = std.debug.assert;

const line_columns_max: u32 = 100;
const function_lines_max: u32 = 70;
const violations_per_file_max: u32 = 256;
const brace_depth_max: u32 = 64;
const line_view_bytes_max: u32 = 4096;
const source_bytes_max: u32 = 1024 * 1024;
const files_max: u32 = 10_000;

/// Shell scripts are banned (build tooling is Zig). A path listed here is allowed, and each
/// entry needs a written reason next to it.
const shell_allowlist = [_][]const u8{
    // The cloud container's SessionStart hook installs the pinned Zig and libpq before any Zig
    // exists to run a program written in Zig. The CI action that does the same is YAML.
    ".claude/hooks/session-start.sh",
    // The simulation fleet's host side (ops/sim-fleet/README.md): `setup.sh` runs on a bare host
    // before any Zig exists there, and `run.sh` is the loop systemd runs, which only fetches,
    // calls `zig build` and pipes `sim_cluster` into `sim_fleet`; the logic is Zig.
    "ops/sim-fleet/setup.sh",
    "ops/sim-fleet/run.sh",
    // Both source run.sh to test its shell functions, which only a shell can call:
    // `test-canary.sh` runs its canary cycle against fake fault-on runners and the built
    // `sim_fleet`, and `test-crash-record.sh` feeds its crash records to `sim_fleet`.
    "ops/sim-fleet/test-canary.sh",
    // Sources run.sh and runs `store_faults_day` against a fake `zig` and the built `sim_fleet`.
    "ops/sim-fleet/test-store-faults.sh",
    "ops/sim-fleet/test-crash-record.sh",
    // Runs demo-b3's guest.sh (a shell script already, below) against fake state directories.
    "ops/demo-b3/test-guest.sh",
    // The demo's three-node start, stop and kill (c1-7 brief): a handful of long-lived processes
    // started side by side and killed by pid file, which is what a shell is for. Each script opens
    // with its own written reason; `down.sh` must work with nothing built.
    "demo/up.sh",
    "demo/down.sh",
    "demo/kill-node.sh",
    // The guest half of `zig build zigbox-smoke` (docs/demos/c2.md): it runs inside the QEMU
    // guest as an ordinary user, where the checks are `pgrep`, `kill -9`, `/sys/fs/cgroup` and
    // `curl` against the server, a few lines each; a Zig program would be one more binary to copy
    // in and would shell out to the same tools. Deviation recorded in the slice's report.
    "ops/zigbox-smoke/guest.sh",
    // The guest half of `zig build demo-c2` (docs/demos/c2.md, "demo-c2"), for the same reason:
    // it starts and restarts the agent as `cube`, writes the test fault, greps fetch logs and,
    // as root, adds the nft rule of step 3 and records the failing `curl`.
    "ops/demo-c2/guest.sh",
    // demo-b3's guest half (docs/demos/b3.md), for the same reason: it starts the agent and a test
    // upstream as root and reads logs and listeners.
    "ops/demo-b3/guest.sh",
    // The owner's one-off recipe for demo-c2's two GHCR images (ops/demo-c2-images): it runs on
    // the owner's machine with docker and a registry login, never in a build or test, and is a
    // list of `docker buildx` calls; the build has no docker to drive from Zig.
    "ops/demo-c2-images/push.sh",
    // CI's changes job (docs/decisions/2026-11-04-ci-affected-demos.md): it runs before any Zig
    // is installed, on a runner that only has git and bash, and decides which jobs install it.
    // Its table test sits beside it and runs in the same job.
    ".github/ci-changes.sh",
    ".github/ci-changes-test.sh",
    // The OpenSSL fixtures of x509_foreign_test.zig (docs/mtls.md): run by hand only to change a
    // fixture, never in a build or test, and nothing but a list of `openssl` calls; the point is
    // certificates another tool made, so the build cannot make them itself.
    "src/testdata/x509/gen.sh",
};

/// `sqlite_c` and `libpq_c` are the translated C headers (`b.addTranslateC` in build.zig).
/// `conformance_options` carries the store suite's build options. `zigbox` is the package of
/// that name (the runtime library and the shared diagnostics), the one dependency besides SQLite
/// and libpq (docs/STYLE.md, "Dependencies").
const module_allowlist = [_][]const u8{
    "std",
    "builtin",
    "build_options",
    "sqlite_c",
    "libpq_c",
    "conformance_options",
    "zigbox",
    "zigbox_vm",
    "web_files",
};

const skipped_directories = [_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg" };

pub const Rule = enum {
    line_too_long,
    tab_character,
    trailing_whitespace,
    function_too_long,
    usize_field,
    import_not_allowed,
    banned_c_import,
    secret_randomness,
    catch_unreachable_without_comment,
    file_name_not_snake_case,
    shell_script,
    unbalanced_braces,
    nesting_too_deep,
    compound_assertion,
    function_name_not_snake_case,

    pub fn message(rule: Rule) []const u8 {
        return switch (rule) {
            .line_too_long => "line is longer than 100 columns",
            .tab_character => "tab character (use 4 spaces)",
            .trailing_whitespace => "trailing whitespace",
            .function_too_long => "function is longer than 70 lines",
            .usize_field => "usize/isize in a struct field (use a sized integer)",
            .import_not_allowed => "@import outside std, builtin, build_options, C and this repo",
            .banned_c_import => "@cImport is gone in Zig 0.17 (use b.addTranslateC)",
            .secret_randomness => "secrets come from secure_random.zig (RB-N9): no " ++
                "KeyPair.generate, crypto.random or randomSecure here",
            .catch_unreachable_without_comment => "unreachable needs a comment saying why",
            .file_name_not_snake_case => "file name is not snake_case",
            .shell_script => "shell scripts are banned unless on the allowlist",
            .unbalanced_braces => "unbalanced braces (tidy lost track of nesting)",
            .nesting_too_deep => "nesting deeper than tidy can follow",
            .compound_assertion => "compound assertion: write assert(a); assert(b);",
            .function_name_not_snake_case => "function name is not snake_case",
        };
    }
};

pub const Violation = struct {
    /// One-based; zero for rules about a whole file.
    line: u32,
    rule: Rule,
};

pub const Report = struct {
    items: [violations_per_file_max]Violation = undefined,
    count: u32 = 0,
    /// Violations beyond capacity are counted but not stored.
    dropped: u32 = 0,

    fn add(report: *Report, line: u32, rule: Rule) void {
        assert(report.count <= violations_per_file_max);
        if (report.dropped > 0) assert(report.count == violations_per_file_max);
        if (report.count == violations_per_file_max) {
            report.dropped += 1;
            return;
        }
        report.items[report.count] = .{ .line = line, .rule = rule };
        report.count += 1;
    }

    pub fn total(report: *const Report) u32 {
        assert(report.count <= violations_per_file_max);
        return report.count + report.dropped;
    }

    pub fn contains(report: *const Report, rule: Rule, line: u32) bool {
        assert(report.count <= violations_per_file_max);
        for (report.items[0..report.count]) |item| {
            if (item.rule == rule and item.line == line) return true;
        }
        return false;
    }
};

// ---- Path-level rules ----------------------------------------------------------------------

pub fn check_path(report: *Report, path: []const u8) void {
    assert(path.len > 0);
    assert(report.count <= violations_per_file_max);
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".sh")) {
        const allowed = for (shell_allowlist) |entry| {
            if (std.mem.eql(u8, entry, path)) break true;
        } else false;
        if (!allowed) report.add(0, .shell_script);
    }
    if (std.mem.endsWith(u8, base, ".zig")) {
        const stem = base[0 .. base.len - ".zig".len];
        if (!is_snake_case(stem)) report.add(0, .file_name_not_snake_case);
    }
}

/// Names the standard library looks up by name, so they cannot be snake_case: `std.json` calls
/// `jsonStringify` and `jsonParse` on a type that declares them.
const std_protocol_names = [_][]const u8{ "jsonStringify", "jsonParse" };

fn is_std_protocol_name(name: []const u8) bool {
    for (std_protocol_names) |allowed| {
        if (std.mem.eql(u8, name, allowed)) return true;
    }
    return false;
}

fn is_snake_case(stem: []const u8) bool {
    assert(std.mem.indexOfScalar(u8, stem, '/') == null); // A stem, never a path.
    if (stem.len == 0) return false;
    for (stem) |byte| {
        const lower = byte >= 'a' and byte <= 'z';
        const digit = byte >= '0' and byte <= '9';
        if (!lower and !digit and byte != '_') return false;
    }
    return true;
}

// ---- Lexing --------------------------------------------------------------------------------

/// Copies `raw` into `view`, replacing comments and the insides of string and character
/// literals with spaces (quotes are kept). Multiline string lines (`\\...`) become blank.
/// Returns the view, which is as long as `raw` or `line_view_bytes_max`, whichever is less.
fn blank_literals(view: *[line_view_bytes_max]u8, raw: []const u8) []const u8 {
    const length = @min(raw.len, view.len);
    @memcpy(view[0..length], raw[0..length]);
    const trimmed = std.mem.trimStart(u8, raw[0..length], " ");
    if (std.mem.startsWith(u8, trimmed, "\\\\")) {
        @memset(view[0..length], ' ');
        return view[0..length];
    }
    var index: usize = 0;
    while (index < length) {
        const byte = raw[index];
        if (byte == '/' and index + 1 < length and raw[index + 1] == '/') {
            @memset(view[index..length], ' ');
            break;
        }
        if (byte == '"' or byte == '\'') {
            index = blank_quoted(view[0..length], raw[0..length], index);
            continue;
        }
        index += 1;
    }
    if (index < length) assert(view[index] == ' ');
    return view[0..length];
}

/// Blanks a quoted literal starting at `start` (which holds the opening quote); returns the
/// index after the closing quote, or `raw.len` for an unterminated literal.
fn blank_quoted(view: []u8, raw: []const u8, start: usize) usize {
    assert(view.len == raw.len);
    const quote = raw[start];
    if (quote != '"') assert(quote == '\'');
    var index = start + 1;
    while (index < raw.len) {
        if (raw[index] == quote) return index + 1;
        const step: usize = if (raw[index] == '\\') 2 else 1;
        const end = @min(index + step, raw.len);
        @memset(view[index..end], ' ');
        index = end;
    }
    return raw.len;
}

/// True if `text` (code view, already trimmed on the right) ends with `word` as a whole word.
fn ends_with_word(text: []const u8, word: []const u8) bool {
    assert(word.len > 0);
    assert(text.len == std.mem.trimEnd(u8, text, " ").len); // Caller trims.
    if (!std.mem.endsWith(u8, text, word)) return false;
    if (text.len == word.len) return true;
    const before = text[text.len - word.len - 1];
    const is_identifier = std.ascii.isAlphanumeric(before) or before == '_' or before == '.';
    return !is_identifier;
}

const BraceKind = enum { other, container, function_body };

/// Classifies the `{` that follows `prefix` (the code before it on the same line).
fn classify_open_brace(prefix: []const u8, function_pending: bool) BraceKind {
    var text = std.mem.trimEnd(u8, prefix, " ");
    // `struct(u32) {` and `union(enum) {`: look through one balanced parenthesis group.
    if (std.mem.endsWith(u8, text, ")")) {
        if (std.mem.lastIndexOfScalar(u8, text, '(')) |open| {
            text = std.mem.trimEnd(u8, text[0..open], " ");
        }
    }
    if (ends_with_word(text, "struct") or ends_with_word(text, "union")) return .container;
    const type_words = [_][]const u8{ "error", "enum", "opaque" };
    for (type_words) |word| {
        if (ends_with_word(text, word)) return .other;
    }
    return if (function_pending) .function_body else .other;
}

fn starts_function_header(code: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, code, " ");
    const prefixes = [_][]const u8{
        "fn ",        "pub fn ",        "export fn ",   "pub export fn ",
        "inline fn ", "pub inline fn ", "noinline fn ", "pub noinline fn ",
        "extern fn ", "pub extern fn ", "test ",        "test{",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return true;
    }
    return std.mem.eql(u8, trimmed, "test");
}

// ---- Per-file state machine ----------------------------------------------------------------

const Frame = struct {
    kind: BraceKind,
    /// For function bodies, the line of the function header.
    start_line: u32,
    /// For function bodies: a `test` block, not a function.
    is_test: bool = false,
};

const Scanner = struct {
    report: *Report,
    stack: [brace_depth_max]Frame = undefined,
    depth: u32 = 0,
    /// Line of a function header whose body brace has not been seen yet; 0 when none.
    pending_line: u32 = 0,
    paren_depth: u32 = 0,
    /// The pending function's name is not snake_case; reported when its body opens, unless the
    /// return type turns out to be `type` (Zig's convention for type constructors).
    pending_bad_name: bool = false,
    pending_is_test: bool = false,
    stopped: bool = false,

    fn scan_line(scanner: *Scanner, line: u32, code: []const u8) void {
        assert(line > 0);
        assert(scanner.depth <= brace_depth_max);
        if (scanner.stopped) return;
        if (scanner.pending_line == 0 and starts_function_header(code)) {
            scanner.pending_line = line;
            scanner.paren_depth = 0;
            scanner.pending_bad_name = false;
            scanner.pending_is_test = is_test_header(code);
            if (function_name(code)) |name| {
                scanner.pending_bad_name = !is_snake_case(name) and !is_std_protocol_name(name);
            }
        }
        if (scanner.depth > 0 and scanner.stack[scanner.depth - 1].kind == .container) {
            if (has_usize_field(code)) scanner.report.add(line, .usize_field);
        }
        for (code, 0..) |byte, index| {
            switch (byte) {
                '(' => scanner.paren_depth += @intFromBool(scanner.pending_line != 0),
                ')' => scanner.paren_depth -|= @intFromBool(scanner.pending_line != 0),
                ';' => if (scanner.paren_depth == 0) {
                    scanner.pending_line = 0;
                    scanner.pending_bad_name = false;
                },
                '{' => scanner.open(line, code[0..index]),
                '}' => scanner.close(line),
                else => {},
            }
            if (scanner.stopped) return;
        }
    }

    fn open(scanner: *Scanner, line: u32, prefix: []const u8) void {
        if (scanner.depth == brace_depth_max) {
            scanner.report.add(line, .nesting_too_deep);
            scanner.stopped = true;
            return;
        }
        const header_open = scanner.pending_line != 0 and scanner.paren_depth == 0;
        var kind = classify_open_brace(prefix, header_open);
        if (scanner.paren_depth > 0 and kind == .function_body) kind = .other;
        var start_line: u32 = line;
        if (kind == .function_body) {
            start_line = scanner.pending_line;
            const returns_type = ends_with_word(std.mem.trimEnd(u8, prefix, " "), "type");
            if (scanner.pending_bad_name and !returns_type) {
                scanner.report.add(start_line, .function_name_not_snake_case);
            }
            scanner.pending_line = 0;
            scanner.pending_bad_name = false;
        }
        const is_test = kind == .function_body and scanner.pending_is_test;
        scanner.stack[scanner.depth] = .{
            .kind = kind,
            .start_line = start_line,
            .is_test = is_test,
        };
        scanner.depth += 1;
    }

    fn close(scanner: *Scanner, line: u32) void {
        if (scanner.depth == 0) {
            scanner.report.add(line, .unbalanced_braces);
            scanner.stopped = true;
            return;
        }
        scanner.depth -= 1;
        const frame = scanner.stack[scanner.depth];
        if (frame.kind != .function_body) return;
        assert(line >= frame.start_line);
        const length = line - frame.start_line + 1;
        if (length > function_lines_max) {
            scanner.report.add(frame.start_line, .function_too_long);
        }
    }
};

fn is_test_header(code: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, code, " ");
    if (std.mem.startsWith(u8, trimmed, "test ")) return true;
    if (std.mem.startsWith(u8, trimmed, "test{")) return true;
    return std.mem.eql(u8, trimmed, "test");
}

/// The identifier after `fn` on a header line, or null for tests and unnamed forms.
fn function_name(code: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, code, " ");
    const marker = std.mem.indexOf(u8, trimmed, "fn ") orelse return null;
    if (marker > 0 and trimmed[marker - 1] != ' ') return null;
    const rest = trimmed[marker + "fn ".len ..];
    var end: usize = 0;
    while (end < rest.len and is_word_byte(rest[end])) end += 1;
    if (end == 0) return null;
    return rest[0..end];
}

/// Reports an `assert(...)` whose argument has a top-level `and` or `or`. `view` has comments
/// and literals blanked. Heuristic: the argument ends at the matching parenthesis, or at the
/// end of the line when it continues onto the next one.
fn check_compound_assertion(report: *Report, line: u32, view: []const u8) void {
    assert(line > 0);
    const needle = "assert(";
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, view, offset, needle)) |found| {
        offset = found + needle.len;
        if (found > 0 and is_word_byte(view[found - 1])) continue;
        var depth: u32 = 1;
        var end = offset;
        while (end < view.len and depth > 0) : (end += 1) {
            if (view[end] == '(') depth += 1;
            if (view[end] == ')') depth -= 1;
        }
        const argument = view[offset..end];
        if (top_level_contains(argument, " and ") or top_level_contains(argument, " or ")) {
            report.add(line, .compound_assertion);
        }
    }
}

/// True if `word` occurs in `text` outside any nested parentheses or brackets.
fn top_level_contains(text: []const u8, word: []const u8) bool {
    assert(word.len > 0);
    var depth: u32 = 0;
    for (text, 0..) |byte, index| {
        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            else => if (depth == 0 and std.mem.startsWith(u8, text[index..], word)) return true,
        }
    }
    return false;
}

/// True if `code` (a line directly inside a struct or union body) declares a field whose type
/// mentions `usize` or `isize`.
fn has_usize_field(code: []const u8) bool {
    const trimmed = std.mem.trim(u8, code, " ");
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return false;
    const name = trimmed[0..colon];
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false; // Not a field name.
    }
    const keywords = [_][]const u8{ "const", "var", "pub", "fn", "comptime", "test", "return" };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return false;
    }
    const type_text = trimmed[colon + 1 ..];
    return contains_word(type_text, "usize") or contains_word(type_text, "isize");
}

fn contains_word(text: []const u8, word: []const u8) bool {
    assert(word.len > 0);
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, text, offset, word)) |found| {
        const before_ok = found == 0 or !is_word_byte(text[found - 1]);
        const end = found + word.len;
        const after_ok = end == text.len or !is_word_byte(text[end]);
        if (before_ok and after_ok) return true;
        offset = found + 1;
    }
    return false;
}

fn is_word_byte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

// ---- Line-level rules ----------------------------------------------------------------------

/// Counts columns as Unicode scalar values (UTF-8 continuation bytes do not count).
fn columns(raw: []const u8) u32 {
    var count: u32 = 0;
    for (raw) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

fn check_physical_line(report: *Report, line: u32, raw: []const u8) void {
    assert(line > 0);
    assert(std.mem.indexOfScalar(u8, raw, '\n') == null);
    if (columns(raw) > line_columns_max) report.add(line, .line_too_long);
    if (std.mem.indexOfScalar(u8, raw, '\t') != null) report.add(line, .tab_character);
    if (raw.len > 0 and (raw[raw.len - 1] == ' ' or raw[raw.len - 1] == '\r')) {
        report.add(line, .trailing_whitespace);
    }
}

fn check_banned_patterns(report: *Report, line: u32, path: []const u8, code: []const u8) void {
    assert(line > 0);
    assert(code.len <= line_view_bytes_max);
    if (std.mem.indexOf(u8, code, "@cImport") != null) report.add(line, .banned_c_import);
    if (!std.mem.eql(u8, path, "src/secure_random.zig")) {
        for (secret_randomness_patterns) |pattern| {
            if (std.mem.indexOf(u8, code, pattern) != null) {
                report.add(line, .secret_randomness);
                return;
            }
        }
    }
    if (io_random_allowed(path)) return;
    for (io_random_patterns) |pattern| {
        if (std.mem.indexOf(u8, code, pattern) != null) {
            report.add(line, .secret_randomness);
            return;
        }
    }
}

/// Ways to draw a secret from somewhere other than `secure_random.zig`. `KeyPair.generate(` is
/// the std call that seeds from `std.crypto.random` (a generator in the process with a fallback);
/// `generateDeterministic(` does not match, because the `(` must follow `generate`. Only
/// `secure_random.zig` may use these. An alias of `KeyPair` or of `std.crypto` is left to review.
const secret_randomness_patterns = [_][]const u8{
    "KeyPair.generate(",
    "crypto.random",
    "randomSecure(",
};

/// `std.Io`'s `random` seeds from a generator that falls back to a weaker source, so it is no
/// source of secrets. It stays for things that are not secret; the files that use it are below.
const io_random_patterns = [_][]const u8{
    "io.random(",
    "Io.random(",
};

/// Files that may call `io.random`, none for a secret: `cli_http.zig` makes a request id suffix,
/// `dir_images.zig` and `peer_files.zig` a temporary file name, `fuzz_seeds.zig`,
/// `store_faults.zig` and `src/testing/` draw the seeds of test runs.
fn io_random_allowed(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/cli_http.zig") or
        std.mem.eql(u8, path, "src/dir_images.zig") or
        std.mem.eql(u8, path, "src/peer_files.zig") or
        std.mem.eql(u8, path, "src/store_faults.zig") or
        std.mem.eql(u8, path, "src/fuzz_seeds.zig") or
        std.mem.startsWith(u8, path, "src/testing/") or
        std.mem.eql(u8, path, "src/secure_random.zig");
}

fn check_unreachable_comment(
    report: *Report,
    line: u32,
    view: []const u8,
    raw: []const u8,
    previous: []const u8,
) void {
    assert(line > 0);
    assert(view.len <= raw.len);
    // Only code counts as a hit; the comment test below must look at the raw text.
    const code_hit = std.mem.indexOf(u8, view, "catch unreachable") != null or
        std.mem.indexOf(u8, view, "orelse unreachable") != null;
    if (!code_hit) return;
    if (std.mem.indexOf(u8, raw, "//") != null) return;
    const before = std.mem.trimStart(u8, previous, " ");
    if (std.mem.startsWith(u8, before, "//")) return;
    report.add(line, .catch_unreachable_without_comment);
}

/// Checks every `@import("...")` on the line. `view` has the literal interiors blanked, so a
/// match in it is real code; the module name is then read from `raw` at the same offsets.
fn check_imports(
    report: *Report,
    line: u32,
    path: []const u8,
    raw: []const u8,
    view: []const u8,
) void {
    assert(line > 0);
    assert(view.len <= raw.len);
    const needle = "@import(\"";
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, view, offset, needle)) |found| {
        const start = found + needle.len;
        const end = std.mem.indexOfScalarPos(u8, view, start, '"') orelse return;
        if (!import_allowed(path, raw[start..end])) report.add(line, .import_not_allowed);
        offset = end + 1;
    }
}

fn import_allowed(importing_path: []const u8, target: []const u8) bool {
    // The readers of the root file: the test-only fault switches (src/agent.zig, sim-c1's
    // src/c1_teeth.zig, and the fetch plan's for `sim-swarm-teeth`).
    if (std.mem.eql(u8, target, "root")) {
        return std.mem.eql(u8, importing_path, "src/agent.zig") or
            std.mem.eql(u8, importing_path, "src/c1_teeth.zig") or
            std.mem.eql(u8, importing_path, "src/fetch_plan.zig") or
            std.mem.eql(u8, importing_path, "src/zcube_agent.zig");
    }
    // The scripted TLS server is a test fixture (docs/briefs/mtls-client.md): only test roots
    // may import it, so no shipped binary can link it.
    if (std.mem.endsWith(u8, target, "tls_testpeer.zig")) return testpeer_importer(importing_path);
    for (module_allowlist) |name| {
        if (std.mem.eql(u8, name, target)) return true;
    }
    const is_file = std.mem.endsWith(u8, target, ".zig") or std.mem.endsWith(u8, target, ".zon");
    if (!is_file or target.len == 0 or target[0] == '/') return false;

    // Walk the path lexically: it may not climb above the repository root.
    var depth: i32 = 0;
    var parts = std.mem.splitScalar(u8, std.fs.path.dirname(importing_path) orelse "", '/');
    while (parts.next()) |part| {
        if (part.len > 0 and !std.mem.eql(u8, part, ".")) depth += 1;
    }
    parts = std.mem.splitScalar(u8, target, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) depth -= 1 else if (part.len > 0) depth += 1;
        if (depth < 0) return false;
    }
    return true;
}

/// The files that may import `tls_testpeer.zig`: test files and test roots (the fuzzer, the
/// diagnostics goldens).
fn testpeer_importer(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, "_test.zig")) return true;
    if (std.mem.eql(u8, path, "src/cli_golden.zig")) return true; // A test root.
    return std.mem.eql(u8, path, "src/tls_fuzz.zig");
}

pub fn check_source(report: *Report, path: []const u8, source: []const u8) void {
    assert(path.len > 0);
    assert(std.mem.endsWith(u8, path, ".zig"));
    var scanner: Scanner = .{ .report = report };
    var lines = std.mem.splitScalar(u8, source, '\n');
    var view_storage: [line_view_bytes_max]u8 = undefined;
    var previous: []const u8 = "";
    var line: u32 = 0;
    while (lines.next()) |raw| {
        line += 1;
        check_physical_line(report, line, raw);
        const view = blank_literals(&view_storage, raw);
        check_banned_patterns(report, line, path, view);
        check_compound_assertion(report, line, view);
        check_unreachable_comment(report, line, view, raw, previous);
        check_imports(report, line, path, raw, view);
        scanner.scan_line(line, view);
        previous = raw;
    }
    if (!scanner.stopped and scanner.depth != 0) report.add(line, .unbalanced_braces);
}

// ---- Command line --------------------------------------------------------------------------

fn skipped(name: []const u8) bool {
    for (skipped_directories) |skip| {
        if (std.mem.eql(u8, skip, name)) return true;
    }
    return false;
}

fn print_violations(out: *std.Io.Writer, path: []const u8, report: *const Report) !void {
    for (report.items[0..report.count]) |item| {
        try out.print("{s}:{d}: {s}\n", .{ path, item.line, item.rule.message() });
    }
    if (report.dropped > 0) try out.print("{s}: {d} more not shown\n", .{ path, report.dropped });
}

/// The root of `zig build mtls-teeth`. A file with a `teeth:` test that it does not import never
/// runs in that gate, so the gate would pass without it.
const teeth_root = "src/mtls_teeth.zig";

/// Files with `teeth:` tests that belong to another gate (the store history checker's, run by
/// `zig build test`), so `teeth_root` does not import them.
const teeth_other_gates = [_][]const u8{"src/testing/history.zig"};

/// True when `source` (the file at `path`) has a `teeth:` test that `root_source` does not
/// import and no other gate owns.
fn teeth_not_imported(path: []const u8, source: []const u8, root_source: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "src/")) return false;
    if (std.mem.eql(u8, path, teeth_root)) return false;
    for (teeth_other_gates) |other| {
        if (std.mem.eql(u8, path, other)) return false;
    }
    if (std.mem.indexOf(u8, source, "test \"teeth:") == null) return false;
    var needle: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&needle, "@import(\"{s}\")", .{path["src/".len..]}) catch
        return true;
    return std.mem.indexOf(u8, root_source, text) == null;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;

    var root = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walkSelectively(arena);
    defer walker.deinit();

    const root_source = try root.readFileAlloc(io, teeth_root, arena, .limited(source_bytes_max));
    var violations: u32 = 0;
    var files: u32 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (!skipped(entry.basename)) try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        files += 1;
        if (files > files_max) return error.TooManyFiles;

        var report: Report = .{};
        check_path(&report, entry.path);
        if (std.mem.endsWith(u8, entry.path, ".zig")) {
            const limit: std.Io.Limit = .limited(source_bytes_max);
            const source = try entry.dir.readFileAlloc(io, entry.basename, arena, limit);
            check_source(&report, entry.path, source);
            if (teeth_not_imported(entry.path, source, root_source)) {
                try out.print("{s}: has teeth: tests that {s} does not import\n", .{
                    entry.path, teeth_root,
                });
                violations += 1;
            }
        }
        try print_violations(out, entry.path, &report);
        violations += report.total();
    }
    if (violations == 0) {
        try out.print("tidy: ok ({d} files checked)\n", .{files});
    } else {
        try out.print("tidy: {d} violations in {d} files checked\n", .{ violations, files });
    }
    try out.flush();
    return if (violations == 0) 0 else 1;
}

// ---- Tests ---------------------------------------------------------------------------------

const testing = std.testing;
const repeat = @import("test_util.zig").repeat;

fn check_text(report: *Report, source: []const u8) void {
    report.* = .{};
    check_source(report, "src/example.zig", source);
}

test "line length: 100 columns pass, 101 fail, multibyte counts as one column" {
    // Goal: the exact boundary, and that UTF-8 text is measured in characters, not bytes.
    var report: Report = undefined;
    const exact = "// " ++ repeat('a', 97);
    check_text(&report, exact);
    try testing.expectEqual(@as(u32, 0), report.total());

    check_text(&report, exact ++ "a");
    try testing.expect(report.contains(.line_too_long, 1));

    const accented = "// " ++ "\u{e9}" ++ repeat('a', 96);
    try testing.expect(accented.len == 101);
    check_text(&report, accented);
    try testing.expectEqual(@as(u32, 0), report.total());
}

test "tabs and trailing whitespace are reported on the right line" {
    var report: Report = undefined;
    check_text(&report, "const a = 1;\n\tconst b = 2;\nconst c = 3; \n");
    try testing.expect(report.contains(.tab_character, 2));
    try testing.expect(report.contains(.trailing_whitespace, 3));
    try testing.expectEqual(@as(u32, 2), report.total());
}

/// Builds `fn f() void {` plus `body_lines` statements plus `}` into `buffer`.
fn function_with_body(buffer: []u8, body_lines: u32) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("fn f() void {\n") catch unreachable; // Sized for the callers below.
    for (0..body_lines) |_| writer.writeAll("    _ = 0;\n") catch unreachable; // Same.
    writer.writeAll("}\n") catch unreachable; // Same.
    return writer.buffered();
}

test "function length: 70 lines pass, 71 fail" {
    // Goal: the boundary. Header and closing brace count, so 68 statements make 70 lines.
    var report: Report = undefined;
    var buffer: [2048]u8 = undefined;
    check_text(&report, function_with_body(&buffer, 68));
    try testing.expectEqual(@as(u32, 0), report.total());
    check_text(&report, function_with_body(&buffer, 69));
    try testing.expect(report.contains(.function_too_long, 1));
    try testing.expectEqual(@as(u32, 1), report.total());
}

test "function length ignores braces in strings, comments and char literals" {
    // Goal: negative space for the lexer. Unbalanced braces in non-code must not confuse it.
    var report: Report = undefined;
    check_text(&report,
        \\fn f() void {
        \\    const a = "}}}";
        \\    const b = '}'; // {{{
        \\    const c = '\'';
        \\    const d = "\"}";
        \\    const e =
        \\        \\}}}
        \\    ;
        \\}
        \\
    );
    try testing.expectEqual(@as(u32, 0), report.total());
}

test "function headers: multi-line signatures, error sets, struct returns, tests" {
    // Goal: the body brace is found even when the signature itself contains braces.
    var report: Report = undefined;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const header = "pub fn g(\n    a: u8,\n) error{A}!struct { x: u8 } {\n";
    writer.writeAll(header) catch unreachable; // Fits.
    for (0..70) |_| writer.writeAll("    _ = 0;\n") catch unreachable; // Fits.
    writer.writeAll("}\ntest \"long\" {\n") catch unreachable; // Fits.
    for (0..70) |_| writer.writeAll("    _ = 0;\n") catch unreachable; // Fits.
    writer.writeAll("}\n") catch unreachable; // Fits.
    check_text(&report, writer.buffered());
    try testing.expect(report.contains(.function_too_long, 1));
    try testing.expect(report.contains(.function_too_long, 75));
    try testing.expectEqual(@as(u32, 2), report.total());
}

test "extern declarations and function types do not start a function" {
    // Goal: a header with no body (ends in `;`) must not swallow the next block.
    var report: Report = undefined;
    check_text(&report,
        \\extern fn declared() void;
        \\const Callback = *const fn () void;
        \\const x = struct {
        \\    a: u8,
        \\};
        \\
    );
    try testing.expectEqual(@as(u32, 0), report.total());
}

test "usize fields are banned in structs and unions but not in functions or consts" {
    // Goal: positive and negative space of the field rule.
    var report: Report = undefined;
    check_text(&report,
        \\const A = struct {
        \\    count: usize,
        \\    items: []const isize,
        \\    ok: u32,
        \\    const limit: usize = 3;
        \\    fn method(length: usize) usize {
        \\        const local: usize = length;
        \\        return local;
        \\    }
        \\};
        \\const B = union(enum) {
        \\    a: ?usize,
        \\};
        \\const C = packed struct(u32) {
        \\    usize_like: u32,
        \\    b: u32 = 0,
        \\};
        \\
    );
    try testing.expect(report.contains(.usize_field, 2));
    try testing.expect(report.contains(.usize_field, 3));
    try testing.expect(report.contains(.usize_field, 12));
    try testing.expectEqual(@as(u32, 3), report.total());
}

test "imports: std and in-repo files pass; escapes, absolute paths and packages fail" {
    // Goal: only std, builtin, build_options and files that stay inside the repository.
    var report: Report = undefined;
    check_text(&report,
        \\const std = @import("std");
        \\const b = @import("builtin");
        \\const o = @import("build_options");
        \\const c = @import("constants.zig");
        \\const d = @import("sub/dir.zig");
        \\const e = @import("../build.zig.zon");
        \\const f = @import("../../outside.zig");
        \\const g = @import("/etc/passwd.zig");
        \\const h = @import("some_package");
        \\const i = @import("../src/x.zig"); const j = @import("evil");
        \\const k = "@import(\"evil\")"; // @import("evil")
        \\const l = @import("sqlite_c");
        \\
    );
    try testing.expect(!report.contains(.import_not_allowed, 1));
    try testing.expect(!report.contains(.import_not_allowed, 4));
    try testing.expect(!report.contains(.import_not_allowed, 5));
    try testing.expect(!report.contains(.import_not_allowed, 6));
    try testing.expect(report.contains(.import_not_allowed, 7));
    try testing.expect(report.contains(.import_not_allowed, 8));
    try testing.expect(report.contains(.import_not_allowed, 9));
    try testing.expect(report.contains(.import_not_allowed, 10));
    var root_report: Report = undefined;
    check_text(&root_report, "const r = @import(\"root\");\n");
    try testing.expect(root_report.contains(.import_not_allowed, 1)); // Not other files.
    try testing.expect(!report.contains(.import_not_allowed, 11));
    try testing.expect(!report.contains(.import_not_allowed, 12));
    try testing.expectEqual(@as(u32, 4), report.total());
}

test "imports: the scripted TLS server is imported only from test roots" {
    // Goal: no shipped module can link the test peer. Method: the same import from a test file,
    // the fuzzer and ordinary modules.
    const source = "const p = @import(\"tls_testpeer.zig\");\n";
    const cases = [_]struct { path: []const u8, allowed: bool }{
        .{ .path = "src/tls_client_test.zig", .allowed = true },
        .{ .path = "src/tls_fuzz.zig", .allowed = true },
        .{ .path = "src/cli_golden.zig", .allowed = true },
        .{ .path = "src/tls_client.zig", .allowed = false },
        .{ .path = "src/zcube_server.zig", .allowed = false },
    };
    for (cases) |case| {
        var report: Report = .{};
        check_source(&report, case.path, source);
        try testing.expectEqual(!case.allowed, report.contains(.import_not_allowed, 1));
    }
}

test "imports from the repository root cannot climb out" {
    // Goal: the depth check is relative to the importing file's directory.
    var report: Report = .{};
    check_source(&report, "build.zig", "const a = @import(\"../x.zig\");\n");
    try testing.expect(report.contains(.import_not_allowed, 1));
    report = .{};
    check_source(&report, "src/testing/vm/a.zig", "const a = @import(\"../../host.zig\");\n");
    try testing.expectEqual(@as(u32, 0), report.total());
}

test "C imports are banned; libc linking is allowed" {
    var report: Report = undefined;
    check_text(&report,
        \\const a = .{ .link_libc = true };
        \\exe.linkLibC();
        \\const c = @cImport(@cInclude("x.h"));
        \\const d = "@cImport"; // @cImport
        \\
    );
    try testing.expect(report.contains(.banned_c_import, 3));
    try testing.expectEqual(@as(u32, 1), report.total());
}

test "secrets are drawn only in secure_random.zig (RB-N9)" {
    // Goal: a key made by `KeyPair.generate`, `std.crypto.random` or a raw `randomSecure` call
    // cannot come back. Method: each in a file that may not, then in the files that may, and the
    // deterministic call, a literal and a comment, which are fine anywhere.
    const source =
        \\const a = Ed25519.KeyPair.generate(io);
        \\const b = std.crypto.random.bytes(&x);
        \\try io.randomSecure(&seed);
        \\const c = Ed25519.KeyPair.generateDeterministic(seed);
        \\const d = "KeyPair.generate("; // KeyPair.generate(
        \\const e = prng.random().int(u8);
        \\
    ;
    const io_source =
        \\env.io.random(&id);
        \\std.Io.random(io, &name);
        \\
    ;
    var report: Report = .{};
    check_source(&report, "src/server_ca.zig", source);
    try testing.expect(report.contains(.secret_randomness, 1));
    try testing.expect(report.contains(.secret_randomness, 2));
    try testing.expect(report.contains(.secret_randomness, 3));
    try testing.expectEqual(@as(u32, 3), report.total());
    report = .{};
    check_source(&report, "src/secure_random.zig", source);
    try testing.expectEqual(@as(u32, 0), report.total());
    report = .{};
    check_source(&report, "src/peer_stream.zig", source);
    try testing.expectEqual(@as(u32, 3), report.total()); // No file but secure_random.zig.
    report = .{};
    check_source(&report, "src/server_ca.zig", io_source);
    try testing.expect(report.contains(.secret_randomness, 1));
    try testing.expect(report.contains(.secret_randomness, 2));
    try testing.expectEqual(@as(u32, 2), report.total());
    for ([_][]const u8{ "src/cli_http.zig", "src/dir_images.zig" }) |path| {
        report = .{};
        check_source(&report, path, io_source);
        try testing.expectEqual(@as(u32, 0), report.total());
    }
}

test "catch unreachable needs a comment on the line or the line above" {
    var report: Report = undefined;
    check_text(&report,
        \\const a = f() catch unreachable;
        \\const b = f() catch unreachable; // Cannot fail: sized above.
        \\// Cannot fail: sized above.
        \\const c = f() catch unreachable;
        \\const d = g() orelse unreachable;
        \\
    );
    try testing.expect(report.contains(.catch_unreachable_without_comment, 1));
    try testing.expect(report.contains(.catch_unreachable_without_comment, 5));
    try testing.expectEqual(@as(u32, 2), report.total());
}

test "assertions: compound conditions are reported, split ones are not" {
    // Goal: `and`/`or` at the top level of assert(...) is flagged; inside nested parentheses,
    // in comments or in strings it is not.
    var report: Report = undefined;
    check_text(&report,
        \\fn f() void {
        \\    assert(a and b);
        \\    assert(a or b); // fine and good
        \\    assert(g(a and b));
        \\    assert(a);
        \\    assert(x == "a and b");
        \\    std.debug.assert(a or b);
        \\    if (a) assert(b);
        \\    const t = a and b;
        \\}
        \\
    );
    try testing.expect(report.contains(.compound_assertion, 2));
    try testing.expect(report.contains(.compound_assertion, 3));
    try testing.expect(!report.contains(.compound_assertion, 4));
    try testing.expect(!report.contains(.compound_assertion, 5));
    try testing.expect(!report.contains(.compound_assertion, 6));
    try testing.expect(report.contains(.compound_assertion, 7));
    try testing.expectEqual(@as(u32, 3), report.total());
}

test "function names must be snake_case, except type constructors" {
    // Goal: `BadName` and `badName` fail; `Generic(comptime T: type) type` passes, also when
    // the signature spans lines; tests and names inside struct bodies are covered too.
    var report: Report = undefined;
    check_text(&report,
        \\pub fn BadName() void {}
        \\fn badName() void {}
        \\fn good_name() void {}
        \\pub fn Generic(comptime T: type) type {
        \\    return T;
        \\}
        \\fn Multi(
        \\    comptime T: type,
        \\) type {
        \\    return T;
        \\}
        \\const S = struct {
        \\    fn Method(self: S) void {
        \\        _ = self;
        \\    }
        \\    pub fn jsonStringify(self: S, jw: anytype) !void {
        \\        _ = self;
        \\        _ = jw;
        \\    }
        \\};
        \\
    );
    try testing.expect(report.contains(.function_name_not_snake_case, 1));
    try testing.expect(report.contains(.function_name_not_snake_case, 2));
    try testing.expect(report.contains(.function_name_not_snake_case, 13));
    try testing.expectEqual(@as(u32, 3), report.total());
}

test "paths: snake_case zig files and the shell allowlist" {
    var report: Report = .{};
    check_path(&report, "src/good_name2.zig");
    check_path(&report, "build.zig");
    try testing.expectEqual(@as(u32, 0), report.total());
    check_path(&report, "src/BadName.zig");
    check_path(&report, "src/kebab-name.zig");
    check_path(&report, "scripts/run.sh");
    check_path(&report, "docs/notes.md");
    try testing.expect(report.contains(.file_name_not_snake_case, 0));
    try testing.expect(report.contains(.shell_script, 0));
    try testing.expectEqual(@as(u32, 3), report.total());
}

test "unbalanced braces are reported instead of mis-measuring" {
    var report: Report = undefined;
    check_text(&report, "fn f() void {\n");
    try testing.expect(report.contains(.unbalanced_braces, 2));
    check_text(&report, "}\n");
    try testing.expect(report.contains(.unbalanced_braces, 1));
}

test "the repository's own sources are clean" {
    // Goal: tidy applied to its own source text reports nothing, which guards against
    // fixtures in this file tripping the rules they test (strings and comments are blanked).
    var report: Report = .{};
    check_source(&report, "src/tidy.zig", @embedFile("tidy.zig"));
    for (report.items[0..report.count]) |item| {
        std.debug.print("tidy.zig:{d}: {s}\n", .{ item.line, item.rule.message() });
    }
    try testing.expectEqual(@as(u32, 0), report.total());
}

test "a file with teeth tests must be imported by the mtls-teeth root" {
    const body = "test \"teeth:" ++ " x\" {}\n";
    const root_source = "test { _ = @import(\"a_test.zig\"); }\n";
    try testing.expect(!teeth_not_imported("src/a_test.zig", body, root_source));
    try testing.expect(teeth_not_imported("src/b_test.zig", body, root_source));
    try testing.expect(!teeth_not_imported("src/b_test.zig", "test \"plain\" {}\n", root_source));
    try testing.expect(!teeth_not_imported("src/testing/history.zig", body, root_source));
    try testing.expect(!teeth_not_imported("tools/x.zig", body, root_source));
}
