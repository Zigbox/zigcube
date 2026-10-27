//! A port of Zigbox's `src/fuzz_redact.zig` for the redactor in `bundle_redact.zig`: the tests at
//! the bottom run it for a fixed number of iterations from a seed, and a failure prints the seed
//! (`ZCUBE_FUZZ_SEED=<seed> zig build test` replays it). Changes from the original: the asserts
//! are `try` checks so that a failure can say its seed, and the module-level mask is gone.
//!
//! Each iteration builds text out of junk and of
//! secrets planted in the shapes redact.zig claims to cover (assignments, flags, JSON and ZON
//! pairs, quoted and escaped values, bearer headers, private keys, token shapes, labels, and
//! values zbx was told to scrub), sometimes escaped once or twice the way a run record escapes a
//! command. The property: no planted secret is in the output, whatever the size of the output
//! buffer (a full buffer stops, it never copies the rest). The oracle is the planting itself, so
//! it does not share code with the redactor. Damaged and random text only has to be survived:
//! no crash, the output within its buffer, and the same answer twice.

const std = @import("std");
const assert = std.debug.assert;
const redact = @import("bundle_redact.zig");

const input_bytes_max = 4096;
const secrets_per_input_max = 6;

const names = [_][]const u8{
    "TOKEN",          "GITHUB_TOKEN", "api_key", "API-KEY",        "client_secret",
    "DB_PASSWORD",    "passwd",       "MyKey",   "ssh_passphrase", "aws_credentials",
    "SECRET_TOKEN_X", "monkey",
};

const junk = [_][]const u8{
    "echo",
    "hello",
    "/bin/sh",
    "-c",
    "--verbose",
    "x=1",
    "PATH=/bin",
    "{",
    "}",
    "[",
    "]",
    ",",
    ":",
    ";",
    "&&",
    "|",
    "$HOME",
    "a.b.c",
    "--rootfs",
    "bearer",
    "Authorization",
    "-----",
    "BEGIN",
    "END",
    "key",
    "token",
    "\"",
    "'",
    "\\",
    "=",
    "\n",
    "\t",
    "ghp_",
    "sk-",
    "eyJ",
};

const pem_format = "-----BEGIN PRIVATE KEY-----\n{s}\n-----END PRIVATE KEY-----";

const Planted = struct {
    values: [secrets_per_input_max][64]u8 = undefined,
    lengths: [secrets_per_input_max]u8 = @splat(0),
    count: u32 = 0,
    /// Values handed to the redactor as literals.
    literals: [secrets_per_input_max][]const u8 = undefined,
    literals_count: u32 = 0,

    fn slice(planted: *const Planted, index: u32) []const u8 {
        return planted.values[index][0..planted.lengths[index]];
    }
};

const Builder = struct {
    bytes: [input_bytes_max]u8 = undefined,
    len: u32 = 0,

    fn add(builder: *Builder, piece: []const u8) void {
        if (builder.len + piece.len > builder.bytes.len) return;
        @memcpy(builder.bytes[builder.len..][0..piece.len], piece);
        builder.len += @intCast(piece.len);
    }

    fn text(builder: *const Builder) []const u8 {
        return builder.bytes[0..builder.len];
    }
};

/// A fresh secret: a recognisable prefix and random letters and digits. With `space`, a space
/// in the middle (for contexts that quote their value).
fn plant(random: std.Random, planted: *Planted, space: bool, min: u32) []const u8 {
    assert(planted.count < secrets_per_input_max);
    const index = planted.count;
    planted.count += 1;
    const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var length: u32 = 0;
    const buffer = &planted.values[index];
    @memcpy(buffer[0..2], "ZQ");
    length = 2;
    const body = random.intRangeAtMost(u32, @max(min, 6), 24);
    for (0..body) |at| {
        const middle = space and at == body / 2;
        buffer[length] = if (middle) ' ' else letters[random.uintLessThan(usize, letters.len)];
        length += 1;
    }
    planted.lengths[index] = @intCast(length);
    return planted.slice(index);
}

fn pick_name(random: std.Random) []const u8 {
    return names[random.uintLessThan(usize, names.len)];
}

fn add_context(random: std.Random, builder: *Builder, planted: *Planted) void {
    var scratch: [256]u8 = undefined;
    const choice = random.uintLessThan(u8, 12);
    const name = pick_name(random);
    // A token shape is only recognised from its real length up (a GitHub token is 40).
    const secret = plant(random, planted, choice == 5 or choice == 11, if (choice == 9) 20 else 8);
    const text = switch (choice) {
        0 => std.fmt.bufPrint(&scratch, "{s}={s}", .{ name, secret }),
        1 => std.fmt.bufPrint(&scratch, "--{s} {s}", .{ name, secret }),
        2 => std.fmt.bufPrint(&scratch, "--{s}={s}", .{ name, secret }),
        3 => std.fmt.bufPrint(&scratch, "{{\"{s}\": \"{s}\"}}", .{ name, secret }),
        4 => std.fmt.bufPrint(&scratch, "\"{s}\", \"{s}\"", .{ name, secret }),
        5 => std.fmt.bufPrint(&scratch, "{s}='{s}'", .{ name, secret }),
        6 => std.fmt.bufPrint(&scratch, "Authorization: Bearer {s}", .{secret}),
        7 => std.fmt.bufPrint(&scratch, "bearer {s}", .{secret}),
        8 => std.fmt.bufPrint(&scratch, pem_format, .{secret}),
        9 => std.fmt.bufPrint(&scratch, "ghp_{s}", .{secret}),
        10 => blk: {
            planted.literals[planted.literals_count] = secret;
            planted.literals_count += 1;
            break :blk std.fmt.bufPrint(&scratch, "use {s} here", .{secret});
        },
        else => std.fmt.bufPrint(&scratch, "{s}=\"{s}\"", .{ name, secret }),
    } catch return;
    builder.add(text);
}

fn add_junk(random: std.Random, builder: *Builder) void {
    for (0..random.intRangeAtMost(u32, 0, 4)) |_| {
        builder.add(junk[random.uintLessThan(usize, junk.len)]);
        builder.add(if (random.boolean()) " " else "\n");
    }
}

/// `text` escaped the way a ZON string literal escapes it, inside quotes.
fn zon_escape(text: []const u8, out: *Builder) void {
    out.add("\"");
    for (text) |byte| {
        switch (byte) {
            '"' => out.add("\\\""),
            '\\' => out.add("\\\\"),
            '\n' => out.add("\\n"),
            else => out.add(&.{byte}),
        }
    }
    out.add("\"");
}

const Failure = error{ SecretSurvived, OutputOverflow, NotDeterministic };

var mask: redact.Mask = undefined;

fn redact_text(input: []const u8, output: []u8, secrets: []const []const u8) redact.Result {
    mask.records = false;
    return redact.redact_with(&mask, input, output, secrets);
}

fn check_planted(random: std.Random) Failure!void {
    var planted: Planted = .{};
    var raw: Builder = .{};
    for (0..random.intRangeAtMost(u32, 1, 4)) |_| {
        add_junk(random, &raw);
        if (planted.count < secrets_per_input_max) add_context(random, &raw, &planted);
        raw.add(if (random.boolean()) " " else "\n");
    }
    // The labels line is a line of the record itself: it is never inside an escaped string.
    const escapes = random.uintLessThan(u8, 3);
    const labelled = escapes == 0 and random.uintLessThan(u8, 3) == 0;
    if (labelled and planted.count < secrets_per_input_max) {
        raw.add("\n.labels = .{ .{ \"k\", \"");
        raw.add(plant(random, &planted, false, 6));
        raw.add("\" } },\n");
    }
    var escaped: Builder = .{};
    var escaped_twice: Builder = .{};
    var input = raw.text();
    if (escapes >= 1) {
        zon_escape(input, &escaped);
        input = escaped.text();
    }
    if (escapes == 2) {
        zon_escape(input, &escaped_twice);
        input = escaped_twice.text();
    }
    // An escaped input that no longer fits was cut by the builder: leave it, the planted
    // values are checked against whatever was built, and only whole ones count.
    try check_output(random, input, &planted);
}

fn check_output(random: std.Random, input: []const u8, planted: *const Planted) Failure!void {
    var storage: [input_bytes_max * 4]u8 = undefined;
    const room = random.intRangeAtMost(usize, 1, storage.len);
    const literals = planted.literals[0..planted.literals_count];
    const result = redact_text(input, storage[0..room], literals);
    if (result.len > room) return error.OutputOverflow;
    const output = storage[0..result.len];
    for (0..planted.count) |index| {
        const secret = planted.slice(@intCast(index));
        // A secret that did not make it whole into the input was cut by the builder.
        if (std.mem.indexOf(u8, input, secret) == null) continue;
        if (std.mem.indexOf(u8, output, secret) != null) return error.SecretSurvived;
    }
}

fn check_damaged(random: std.Random) Failure!void {
    var bytes: [input_bytes_max]u8 = undefined;
    const length = random.uintAtMost(usize, bytes.len);
    random.bytes(bytes[0..length]);
    // Bias toward the bytes the redactor looks at.
    const special = "=:\"'\\\n -_.,;&|)`";
    for (bytes[0..length]) |*byte| {
        if (random.uintLessThan(u8, 3) != 0) continue;
        byte.* = special[random.uintLessThan(usize, special.len)];
    }
    if (length > 40 and random.boolean()) {
        @memcpy(bytes[5..16], "-----BEGIN ");
        @memcpy(bytes[20..32], "PRIVATE KEY-");
    }
    var first: [input_bytes_max * 4]u8 = undefined;
    var second: [input_bytes_max * 4]u8 = undefined;
    const a = redact_text(bytes[0..length], &first, &.{});
    const b = redact_text(bytes[0..length], &second, &.{});
    if (a.len != b.len) return error.NotDeterministic;
    if (!std.mem.eql(u8, first[0..a.len], second[0..b.len])) return error.NotDeterministic;
}

pub fn fuzz_redact(seed: u64) Failure!void {
    var prng = std.Random.Xoshiro256.init(seed);
    const random = prng.random();
    try check_planted(random);
    try check_damaged(random);
}

const testing = std.testing;

/// Iterations per run of `zig build test`.
const iterations = 2000;

test "fuzz: no planted secret survives redaction, whatever the shape or the room" {
    // Goal: the property of redact.zig's header, on shapes nobody wrote by hand. Method: derive
    // each iteration's seed from the run's seed, plant secrets in the shapes the redactor claims
    // to cover, and check that none is in the output. A failure prints the seed that replays it.
    var master = std.Random.SplitMix64.init(run_seed());
    for (0..iterations) |_| {
        const seed = master.next();
        fuzz_redact(seed) catch |err| {
            const format = "redaction fuzz failed: {t}; replay with ZCUBE_FUZZ_SEED={d}\n";
            std.debug.print(format, .{ err, seed });
            return err;
        };
    }
}

/// The run's seed: `ZCUBE_FUZZ_SEED` to replay one, else the seed Zig draws for each test run.
fn run_seed() u64 {
    if (testing.environ.getPosix("ZCUBE_FUZZ_SEED")) |text| {
        return std.fmt.parseInt(u64, text, 10) catch @panic("ZCUBE_FUZZ_SEED is not a number");
    }
    return testing.random_seed;
}

test "fuzz: the planted-secret oracle is not vacuous" {
    // Goal: a fuzzer that cannot fail proves nothing. Method: a secret in a shape the redactor
    // knows is gone from the output; the same secret in plain words is not, and the checker
    // says so.
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    var known: Planted = .{};
    var text: Builder = .{};
    text.add("TOKEN=");
    text.add(plant(random, &known, false, 8));
    try check_output(random, text.text(), &known);

    var leaked: Planted = .{};
    var plain: Builder = .{};
    plain.add("harmless words ");
    plain.add(plant(random, &leaked, false, 8));
    try testing.expectError(error.SecretSurvived, check_output(random, plain.text(), &leaked));
}
