//! A port of Zigbox's `src/redact.zig` (Zigbox's package does not export it), so a Zigcube bundle
//! redacts the way a Zigbox one does; keep the two in step. Changes from the original: the sizes
//! come from Zigcube's constants, and the module-level mask is gone (a caller owns its mask).
//!
//! Redaction of text that goes into a bundle (DIAGNOSTICS.md, "Redaction by default"). A secret
//! becomes `[redacted:<kind>]`. The redactor works on text, in one pass, into a bounded buffer,
//! and fails closed: when the output would not fit it stops and says it was cut, it never
//! copies the rest unredacted.
//!
//! What it recognises, in the order it is tried at each position:
//!   1. a secret value zbx was given (the values of secret-named environment variables), found
//!      anywhere in the text, so a command that repeats one is covered;
//!   2. a private key block, from `-----BEGIN ... PRIVATE KEY-----` to its END line (or the end
//!      of the text when the block is cut off);
//!   3. well-known token shapes (GitHub, GitLab, Slack, AWS, Google, OpenAI, JWT);
//!   4. `Bearer <token>` and `Authorization: <scheme> <token>`;
//!   5. a secret *name* with a value: `NAME=value`, `NAME: value`, `--name value`, a JSON or ZON
//!      pair, or two strings in a row (`"api_key", "value"`). A name is secret when it contains
//!      `token`, `secret`, `password`, `passwd`, `passphrase` or `credential`, or ends in `key`;
//!   6. the values of the labels in a run record, always: labels are free text from the user.
//!
//! It is a net, not a proof: a secret with an innocent name and no known shape can pass, which
//! is why the manifest tells the user to review the bundle before sharing it.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

pub const Kind = enum {
    env,
    token,
    key,
    secret,
    password,
    credential,
    bearer,
    authorization,
    private_key,
    label,

    pub fn text(kind: Kind) []const u8 {
        assert(@tagName(kind).len > 0);
        return switch (kind) {
            .private_key => "private-key",
            else => @tagName(kind),
        };
    }
};

pub const Result = struct {
    /// Bytes written to the output.
    len: u32,
    /// How many secrets were replaced.
    redactions: u32,
    /// The output buffer filled up; the rest of the input was dropped.
    truncated: bool,
};

const Out = struct {
    buffer: []u8,
    len: u32 = 0,
    redactions: u32 = 0,
    truncated: bool = false,

    fn put(out: *Out, bytes: []const u8) void {
        assert(out.len <= out.buffer.len);
        if (out.truncated) return;
        if (out.len + bytes.len > out.buffer.len) {
            out.truncated = true;
            return;
        }
        @memcpy(out.buffer[out.len..][0..bytes.len], bytes);
        out.len += @intCast(bytes.len);
        assert(out.len <= out.buffer.len);
    }

    fn mark(out: *Out, kind: Kind) void {
        assert(out.redactions < std.math.maxInt(u32));
        out.put("[redacted:");
        out.put(kind.text());
        out.put("]");
        out.redactions += 1;
        assert(out.redactions > 0);
    }
};

/// Which bytes of the input are secret, and of what kind (the `Kind` plus one; zero for none).
/// Every rule marks bytes and none consumes the text, so a secret inside another rule's value is
/// still found by its own rule.
pub const Mask = struct {
    kinds: [constants.bundle_file_bytes_max]u8,
    /// The text is JSON of store records, where `"key"` names the path of a store key and not a
    /// secret. Set by the caller before each use; the rest of the rules stay on.
    records: bool = false,

    fn mark(mask: *Mask, start: usize, end: usize, kind: Kind) void {
        assert(start <= end);
        assert(end <= mask.kinds.len);
        const value = @as(u8, @backingInt(kind)) + 1;
        for (mask.kinds[start..end]) |*slot| {
            if (slot.* == 0) slot.* = value;
        }
    }
};

/// Redacts `input` into `output` with a mask the caller owns (the bundle keeps one in its
/// workspace). `secrets` are literal values to remove wherever they occur.
pub fn redact_with(
    mask: *Mask,
    input: []const u8,
    output: []u8,
    secrets: []const []const u8,
) Result {
    assert(output.len > 0);
    assert(input.len <= constants.bundle_file_bytes_max);
    assert(secrets.len <= constants.bundle_secrets_max);
    @memset(mask.kinds[0..input.len], 0);
    find_secrets(input, secrets, mask);
    var out: Out = .{ .buffer = output };
    var at: usize = 0;
    while (at < input.len and !out.truncated) {
        const value = mask.kinds[at];
        if (value == 0) {
            out.put(input[at..][0..1]);
            at += 1;
            continue;
        }
        var end = at;
        while (end < input.len and mask.kinds[end] == value) end += 1;
        out.mark(@fromBackingInt(@intCast(value - 1)));
        at = end;
    }
    assert(out.len <= output.len);
    return .{ .len = out.len, .redactions = out.redactions, .truncated = out.truncated };
}

/// Runs every rule at every place it could start.
fn find_secrets(input: []const u8, secrets: []const []const u8, mask: *Mask) void {
    assert(secrets.len <= constants.bundle_secrets_max);
    for (0..input.len) |at| {
        if (literal_at(input[at..], secrets)) |length| mask.mark(at, at + length, .env);
        if (input[at] == '-') {
            if (private_key_end(input, at)) |end| mask.mark(at, end, .private_key);
        }
        const line_start = at == 0 or input[at - 1] == '\n';
        if (line_start and labels_line(input, at) != null) mask_labels(input, at, mask);
        if (!is_name_byte(input[at])) continue;
        if (at > 0 and is_name_byte(input[at - 1])) continue; // Inside a word.
        mask_word(input, at, mask);
        // The letter of an escape (`\n`, `\t`, `\r`) is not part of the word after it: a record
        // keeps newlines as `\n`, and the next line's first word starts right behind it.
        const escaped = at > 0 and input[at - 1] == '\\';
        if (escaped and std.mem.indexOfScalar(u8, "ntr", input[at]) != null) {
            if (at + 1 < input.len and is_name_byte(input[at + 1])) mask_word(input, at + 1, mask);
        }
    }
}

fn is_name_byte(byte: u8) bool {
    assert(@sizeOf(u8) == 1);
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.';
}

fn is_blank(byte: u8) bool {
    assert(@sizeOf(u8) == 1);
    return byte == ' ' or byte == '\t';
}

/// The length of the first secret that `text` starts with, if any.
fn literal_at(text: []const u8, secrets: []const []const u8) ?usize {
    assert(secrets.len <= constants.bundle_secrets_max);
    for (secrets) |secret| {
        if (secret.len < constants.secret_value_bytes_min) continue;
        if (std.mem.startsWith(u8, text, secret)) return secret.len;
    }
    return null;
}

// ---- Private keys --------------------------------------------------------------------------

const pem_begin = "-----BEGIN ";
const pem_end = "-----END ";
const pem_rule = "-----";
const pem_label = "PRIVATE KEY";

/// The index just past a private key block that starts at `at`, or null if none does.
fn private_key_end(input: []const u8, at: usize) ?usize {
    assert(at < input.len);
    assert(input[at] == '-');
    if (!std.mem.startsWith(u8, input[at..], pem_begin)) return null;
    const label_start = at + pem_begin.len;
    const window = input[label_start..@min(input.len, label_start + 64)];
    const rule = std.mem.indexOf(u8, window, pem_rule) orelse return null;
    if (!std.mem.endsWith(u8, window[0..rule], pem_label)) return null;
    const body = label_start + rule + pem_rule.len;
    const end_line = std.mem.indexOfPos(u8, input, body, pem_end) orelse return input.len;
    const close = std.mem.indexOfPos(u8, input, end_line + pem_end.len, pem_rule) orelse
        return input.len;
    return close + pem_rule.len;
}

// ---- Words ---------------------------------------------------------------------------------

const Shape = struct { prefix: []const u8, length_min: usize };

const token_shapes = [_]Shape{
    .{ .prefix = "ghp_", .length_min = 20 },
    .{ .prefix = "gho_", .length_min = 20 },
    .{ .prefix = "ghu_", .length_min = 20 },
    .{ .prefix = "ghs_", .length_min = 20 },
    .{ .prefix = "ghr_", .length_min = 20 },
    .{ .prefix = "github_pat_", .length_min = 30 },
    .{ .prefix = "glpat-", .length_min = 20 },
    .{ .prefix = "xoxb-", .length_min = 15 },
    .{ .prefix = "xoxp-", .length_min = 15 },
    .{ .prefix = "xoxa-", .length_min = 15 },
    .{ .prefix = "xoxs-", .length_min = 15 },
    .{ .prefix = "sk-", .length_min = 20 },
    .{ .prefix = "AKIA", .length_min = 20 },
    .{ .prefix = "ASIA", .length_min = 20 },
    .{ .prefix = "AIza", .length_min = 30 },
    .{ .prefix = "eyJ", .length_min = 30 },
};

fn has_token_shape(word: []const u8) bool {
    assert(word.len > 0);
    for (token_shapes) |shape| {
        if (word.len >= shape.length_min and std.mem.startsWith(u8, word, shape.prefix)) {
            return true;
        }
    }
    return false;
}

fn contains_ci(name: []const u8, needle: []const u8) bool {
    assert(needle.len > 0);
    return std.ascii.findIgnoreCase(name, needle) != null;
}

/// The kind of secret a name stands for, or null if the name is not secret-like.
pub fn secret_kind(name: []const u8) ?Kind {
    assert(name.len <= constants.bundle_file_bytes_max);
    if (contains_ci(name, "password") or contains_ci(name, "passwd")) return .password;
    if (contains_ci(name, "passphrase")) return .password;
    if (contains_ci(name, "secret")) return .secret;
    if (contains_ci(name, "token")) return .token;
    if (contains_ci(name, "credential")) return .credential;
    if (std.ascii.endsWithIgnoreCase(name, "key")) return .key;
    return null;
}

fn mask_word(input: []const u8, at: usize, mask: *Mask) void {
    assert(at < input.len);
    assert(is_name_byte(input[at]));
    var end = at;
    while (end < input.len and is_name_byte(input[end])) end += 1;
    const word = input[at..end];
    if (has_token_shape(word)) mask.mark(at, end, .token);
    if (std.ascii.eqlIgnoreCase(word, "bearer")) {
        var start = end;
        while (start < input.len and is_blank(input[start])) start += 1;
        const value = value_at(input, start, false);
        if (start > end and value != null) mask.mark(value.?.start, value.?.end, .bearer);
    }
    if (std.ascii.eqlIgnoreCase(word, "authorization")) {
        if (authorization_value(input, end)) |span| mask.mark(span.start, span.end, .authorization);
    }
    const store_key = mask.records and std.mem.eql(u8, word, "key");
    if (secret_kind(word)) |kind| {
        if (store_key) return;
        const quoted_name = at > 0 and (input[at - 1] == '"' or input[at - 1] == '\'');
        if (assigned_value(input, end, word[0] == '-', quoted_name)) |value| {
            mask.mark(value.start, value.end, kind);
        }
    }
}

/// `Authorization: Basic abc` and `"authorization": "Bearer abc"`: the scheme and the
/// credential both go. Null if the word is not followed by a value.
fn authorization_value(input: []const u8, name_end: usize) ?Span {
    assert(name_end <= input.len);
    assert(name_end > 0);
    var start = name_end;
    if (start < input.len and (input[start] == '"' or input[start] == '\'')) start += 1;
    while (start < input.len and is_blank(input[start])) start += 1;
    if (start >= input.len or (input[start] != ':' and input[start] != '=')) return null;
    start += 1;
    while (start < input.len and is_blank(input[start])) start += 1;
    const first = value_at(input, start, false) orelse return null;
    if (first.end == first.start) return null;
    var stop = first.end;
    var second = stop;
    while (second < input.len and is_blank(input[second])) second += 1;
    if (second > stop and second < input.len) {
        const next = value_at(input, second, false).?;
        if (next.end > next.start) stop = next.end;
    }
    return .{ .start = first.start, .end = stop };
}

const Span = struct { start: usize, end: usize };

/// The value after a secret name, if the text has the shape of an assignment there.
fn assigned_value(input: []const u8, name_end: usize, is_flag: bool, quoted: bool) ?Span {
    assert(name_end <= input.len);
    assert(name_end > 0);
    var at = name_end;
    // The quote that closes a quoted name, escaped any number of times.
    var slashes: usize = 0;
    while (at + slashes < input.len and input[at + slashes] == '\\') slashes += 1;
    if (at + slashes < input.len and (input[at + slashes] == '"' or input[at + slashes] == '\'')) {
        at += slashes + 1;
    }
    const blank_start = at;
    while (at < input.len and is_blank(input[at])) at += 1;
    var separated = false;
    if (at < input.len and (input[at] == '=' or input[at] == ':')) {
        separated = true;
    } else if (at < input.len and input[at] == ',' and (is_flag or quoted)) {
        separated = true;
    } else if (!(is_flag and at > blank_start)) {
        return null;
    }
    if (separated) at += 1;
    while (at < input.len and is_blank(input[at])) at += 1;
    if (at >= input.len) return null;
    // `--password --verbose`: the next flag is not a value.
    if (!separated and input[at] == '-') return null;
    const span = value_at(input, at, true) orelse return null;
    if (span.end == span.start) return null;
    return span;
}

/// The value that starts at `at`: the inside of a quoted string (the quotes stay), or a run up
/// to a terminator. A secret with a terminator inside it is cut short, which is the safe side
/// of "too little" only for the characters after it; the net is documented as a net.
fn value_at(input: []const u8, at: usize, allow_quoted: bool) ?Span {
    assert(at <= input.len);
    if (at >= input.len) return null;
    const first = input[at];
    if (allow_quoted and first == '\\') {
        // A string escaped once or more (a quoted word inside a quoted word): it ends at the
        // same run of backslashes and a quote.
        var slashes: usize = 0;
        while (at + slashes < input.len and input[at + slashes] == '\\') slashes += 1;
        const opened = at + slashes < input.len and input[at + slashes] == '"';
        if (!opened) return .{ .start = at, .end = at };
        const start = at + slashes + 1;
        const end = std.mem.indexOfPos(u8, input, start, input[at .. at + slashes + 1]);
        return .{ .start = start, .end = end orelse input.len };
    }
    if (allow_quoted and (first == '"' or first == '\'')) {
        const start = at + 1;
        var end = start;
        while (end < input.len and input[end] != first) {
            end += if (input[end] == '\\') 2 else 1;
        }
        return .{ .start = start, .end = @min(end, input.len) };
    }
    // A private key is one value, whatever it holds inside.
    if (first == '-') {
        if (private_key_end(input, at)) |after| return .{ .start = at, .end = after };
    }
    var end = at;
    while (end < input.len and !is_terminator(input[end])) end += 1;
    return .{ .start = at, .end = end };
}

fn is_terminator(byte: u8) bool {
    assert(@sizeOf(u8) == 1);
    return switch (byte) {
        ' ', '\t', '\n', '\r', '"', '\'', '\\', ';', '&', '|', ')', '`' => true,
        else => false,
    };
}

// ---- Labels --------------------------------------------------------------------------------

const labels_key = ".labels = ";

/// The index where the labels value starts when the line at `at` is the record's labels line.
fn labels_line(input: []const u8, at: usize) ?usize {
    assert(at <= input.len);
    var start = at;
    while (start < input.len and is_blank(input[start])) start += 1;
    if (!std.mem.startsWith(u8, input[start..], labels_key)) return null;
    return start + labels_key.len;
}

/// Marks the contents of every label value: strings alternate key, value, key, value.
fn mask_labels(input: []const u8, at: usize, mask: *Mask) void {
    if (at > 0) assert(input[at - 1] == '\n'); // Only called at the start of a line.
    const value_start = labels_line(input, at).?;
    const line_end = std.mem.indexOfScalarPos(u8, input, at, '\n') orelse input.len;
    var index = value_start;
    var strings: u32 = 0;
    while (index < line_end) {
        if (input[index] != '"') {
            index += 1;
            continue;
        }
        var end = index + 1;
        while (end < line_end and input[end] != '"') end += if (input[end] == '\\') 2 else 1;
        end = @min(end, line_end);
        if (strings % 2 == 1) mask.mark(index + 1, end, .label);
        strings += 1;
        index = @min(end + 1, line_end);
    }
}

// ---- Records -------------------------------------------------------------------------------

pub const JsonError = error{ OutOfMemory, NotJson };

/// What stands in for the value of an environment variable of a service or replica record.
pub const env_marker = "[redacted:env]";

/// `text` is JSON holding store records; every `env` value in it is replaced with `env_marker`
/// whatever its name (DIAGNOSTICS.md: "every environment value"), and the names stay. The walk
/// uses an explicit stack, not recursion. The textual rules above are the net behind this; this
/// is the rule that does not depend on a secret looking like one.
pub fn redact_env_values(arena: std.mem.Allocator, text: []const u8) JsonError![]const u8 {
    assert(text.len <= constants.cli_reply_bytes_max);
    var root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.NotJson;
    };
    var stack: std.ArrayList(*std.json.Value) = .empty;
    try stack.append(arena, &root);
    while (stack.pop()) |node| {
        switch (node.*) {
            .object => |*object| {
                var entries = object.iterator();
                while (entries.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "env")) blank_values(entry.value_ptr);
                    try stack.append(arena, entry.value_ptr);
                }
            },
            .array => |*array| {
                for (array.items) |*item| try stack.append(arena, item);
            },
            else => {},
        }
    }
    return std.json.Stringify.valueAlloc(arena, root, .{}) catch error.OutOfMemory;
}

/// The values of an `env`: `[["KEY", "value"], ...]` or `{"KEY": "value"}`. A null value (the
/// API's own redaction) stays null.
fn blank_values(env: *std.json.Value) void {
    switch (env.*) {
        .array => |*pairs| {
            for (pairs.items) |*pair| {
                if (pair.* != .array or pair.array.items.len != 2) continue;
                if (pair.array.items[1] == .string) pair.array.items[1] = .{ .string = env_marker };
            }
        },
        .object => |*object| {
            var entries = object.iterator();
            while (entries.next()) |entry| {
                if (entry.value_ptr.* == .string) entry.value_ptr.* = .{ .string = env_marker };
            }
        },
        else => {},
    }
}

// ---- Tests ---------------------------------------------------------------------------------

const testing = std.testing;

var test_mask: Mask = undefined;

fn redact(input: []const u8, output: []u8, secrets: []const []const u8) Result {
    return redact_with(&test_mask, input, output, secrets);
}

fn run_redact(input: []const u8, secrets: []const []const u8, storage: []u8) []const u8 {
    const result = redact(input, storage, secrets);
    return storage[0..result.len];
}

fn expect_redacted(input: []const u8, expected: []const u8) !void {
    var storage: [1024]u8 = undefined;
    try testing.expectEqualStrings(expected, run_redact(input, &.{}, &storage));
}

test "assignments: the value goes, the name stays" {
    // Goal: the shapes the brief names. Method: one input per shape, exact output.
    try expect_redacted("TOKEN=abc123", "TOKEN=[redacted:token]");
    try expect_redacted(
        "export GITHUB_TOKEN=x1 FOO=bar",
        "export GITHUB_TOKEN=[redacted:token] FOO=bar",
    );
    try expect_redacted("--password=hunter2 --x", "--password=[redacted:password] --x");
    try expect_redacted("--password hunter2 --x", "--password [redacted:password] --x");
    try expect_redacted("--password --verbose", "--password --verbose");
    try expect_redacted(
        "AWS_SECRET_ACCESS_KEY=abc/def+g=",
        "AWS_SECRET_ACCESS_KEY=[redacted:secret]",
    );
    try expect_redacted("API_KEY: sk_live", "API_KEY: [redacted:key]");
    try expect_redacted("DB_PASSWORD='a b c' next", "DB_PASSWORD='[redacted:password]' next");
    try expect_redacted("KEEP=1 PATH=/bin", "KEEP=1 PATH=/bin");
    try expect_redacted("TOKEN= next", "TOKEN= [redacted:token]"); // Safe side.
}

test "run record shapes: escaped quotes, word lists and json pairs" {
    try expect_redacted(
        ".command = .{ \"sh\", \"-c\", \"curl -H x --token=abc; id\" },",
        ".command = .{ \"sh\", \"-c\", \"curl -H x --token=[redacted:token]; id\" },",
    );
    try expect_redacted(
        ".command = .{ \"app\", \"--password\", \"hunter2\" },",
        ".command = .{ \"app\", \"--password\", \"[redacted:password]\" },",
    );
    try expect_redacted(
        "{\"api_key\":\"abc\",\"n\":1}",
        "{\"api_key\":\"[redacted:key]\",\"n\":1}",
    );
    try expect_redacted(
        "\"sh -c \\\"export PASSWORD=\\\\\\\"p w\\\\\\\"\\\"\"",
        "\"sh -c \\\"export PASSWORD=\\\\\\\"[redacted:password]\\\\\\\"\\\"\"",
    );
}

test "bearer headers and authorization values" {
    try expect_redacted(
        "curl -H 'Authorization: Bearer abc.def' x",
        "curl -H 'Authorization: [redacted:authorization]' x",
    );
    try expect_redacted(
        "Authorization: Basic dXNlcjpwdw==",
        "Authorization: [redacted:authorization]",
    );
    try expect_redacted("got bearer  tok123 ok", "got bearer  [redacted:bearer] ok");
    try expect_redacted("a bearer of news", "a bearer [redacted:bearer] news"); // Prose is a cost.
    try expect_redacted("bearer", "bearer");
}

test "private keys, whole and cut off" {
    try expect_redacted(
        "a -----BEGIN RSA PRIVATE KEY-----\\nMIIE\\n-----END RSA PRIVATE KEY----- b",
        "a [redacted:private-key] b",
    );
    try expect_redacted("x -----BEGIN PRIVATE KEY-----\nMIIE", "x [redacted:private-key]");
    try expect_redacted("-----BEGIN CERTIFICATE-----\nMIIE", "-----BEGIN CERTIFICATE-----\nMIIE");
}

test "token shapes and literal secrets" {
    try expect_redacted("t=ghp_0123456789abcdefghij0123 z", "t=[redacted:token] z");
    try expect_redacted("AKIAIOSFODNN7EXAMPLE", "[redacted:token]");
    try expect_redacted("ghp_short", "ghp_short");
    var storage: [256]u8 = undefined;
    const secrets = [_][]const u8{ "s3cr3t-value", "xy" };
    const text = run_redact("use s3cr3t-value, and xy", &secrets, &storage);
    try testing.expectEqualStrings("use [redacted:env], and xy", text); // Too short to scrub.
}

test "a token after an escaped newline is still a token" {
    // Goal: a run record keeps newlines as backslash-n, so the next word starts after a letter.
    try expect_redacted("a\\nghp_0123456789abcdefghij0123", "a\\n[redacted:token]");
    try expect_redacted("a\\nbearer tok", "a\\nbearer [redacted:bearer]");
    try expect_redacted("a\\nTOKEN=x", "a\\nTOKEN=[redacted:token]");
}

test "labels: keys stay, every value goes" {
    try expect_redacted(
        "    .labels = .{ .{ \"app\", \"web\" }, .{ \"tier\", \"\" } },\n    .started = 1,\n",
        "    .labels = .{ .{ \"app\", \"[redacted:label]\" }, " ++
            ".{ \"tier\", \"\" } },\n    .started = 1,\n", // An empty value hides nothing.
    );
    try expect_redacted(".labels = .{ },\n", ".labels = .{ },\n");
}

test "a full output stops and says so, and never copies the rest" {
    var storage: [16]u8 = undefined;
    const result = redact("0123456789 TOKEN=abcdefghijklmnop tail", &storage, &.{});
    try testing.expect(result.truncated);
    try testing.expect(std.mem.indexOf(u8, storage[0..result.len], "abcdef") == null);
}

test "secret_kind: the names the brief lists, and not their neighbours" {
    try testing.expectEqual(@as(?Kind, .token), secret_kind("GITHUB_TOKEN"));
    try testing.expectEqual(@as(?Kind, .key), secret_kind("api-key"));
    try testing.expectEqual(@as(?Kind, .password), secret_kind("MYSQL_PASSWORD"));
    try testing.expectEqual(@as(?Kind, .secret), secret_kind("client_secret"));
    try testing.expectEqual(@as(?Kind, null), secret_kind("keyboard"));
    try testing.expectEqual(@as(?Kind, null), secret_kind("HOME"));
}

test "env values of records go, whatever their names, and the names stay" {
    // Goal: DIAGNOSTICS.md, "every environment value". Method: a service record with an innocent
    // name, a secret-looking one, a null (the API's own redaction) and an env in a replica.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input =
        \\{"kvs":[{"key":"/services/hello","value":{"name":"hello",
        \\"env":[["GREETING","hi there"],["DB_PASSWORD","hunter2"],["HIDDEN",null]]}},
        \\{"key":"/replicas/hello/hello-1",
        \\"value":{"env":{"A":"b"},"command":["sh","-c","echo env"]}}]}
    ;
    const output = try redact_env_values(arena, input);
    try testing.expect(std.mem.indexOf(u8, output, "hi there") == null);
    try testing.expect(std.mem.indexOf(u8, output, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"GREETING\",\"[redacted:env]\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"HIDDEN\",null") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"A\":\"[redacted:env]\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"echo env\"") != null); // Not an env.
    try testing.expectError(error.NotJson, redact_env_values(arena, "{\"cut\":"));
}
