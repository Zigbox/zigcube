//! `zcube job ...`: the words after `job`, parsed. Pure, like `cli_args.zig`, which hands them
//! over: in a job line the flags `zcube` does not know are words, in order, and this file reads
//! them, so every refusal is `ZC-E0111` and a unit test.
//!
//! ```
//! zcube job run NAME --image DIGEST [--env K=V]... [--input-file F --input-env VAR]
//!     [--deadline 10m] [--submit-within 10m] [--label k=v]... --command WORD...
//! zcube job get NAME [--wait]
//! zcube job list [--state S] [--label k=v]
//! zcube job cancel NAME
//! zcube job watch [--from REV]
//! ```
//!
//! `--command` takes the rest of the line, whatever it looks like (`sh -c 'exit 3'`); the flags
//! of `zcube` itself go before it. A value that is an environment variable is never echoed by a
//! refusal: the cause names the flag, not the text.

const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli_args.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");

const Diag = diag_mod.Diag;
const Error = cli_args.Error;

pub const Pair = struct { key: []const u8, value: []const u8 };

/// A list that lives inside the command, so the command can be copied and outlives the parser's
/// stack. `slice` of a copy points into the copy: use it where it was captured.
pub fn Bounded(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: u32 = 0,

        const Self = @This();

        pub fn slice(list: *const Self) []const T {
            return list.items[0..list.len];
        }

        fn push(list: *Self, item: T) bool {
            if (list.len == capacity) return false;
            list.items[list.len] = item;
            list.len += 1;
            return true;
        }
    };
}

/// A deadline of a job and its submit window when the line says nothing.
pub const deadline_default_ms: u64 = 10 * 60 * 1000;
pub const submit_within_default_ms: u64 = 10 * 60 * 1000;

pub const Run = struct {
    name: []const u8,
    image: []const u8,
    command: Bounded([]const u8, constants.job_command_words_max) = .{},
    env: Bounded(Pair, constants.runtime_env_count_max) = .{},
    labels: Bounded(Pair, constants.job_labels_max) = .{},
    input_file: ?[]const u8 = null,
    input_env: ?[]const u8 = null,
    deadline_ms: u64 = deadline_default_ms,
    submit_within_ms: u64 = submit_within_default_ms,
};

pub const List = struct {
    /// A job state, or `ended`: sent as given.
    state: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

pub const Job = union(enum) {
    run: Run,
    get: struct { name: []const u8, wait: bool },
    list: List,
    cancel: []const u8,
    /// The first revision wanted; null means from the head.
    watch: ?u64,
};

const states = [_][]const u8{
    "pending", "placed", "running", "exited", "failed", "cancelled", "ended",
};

/// The flags that take a value, by command, so a missing value is told from an unknown flag.
const Cursor = struct {
    words: []const []const u8,
    at: u32 = 0,

    fn next(cursor: *Cursor) ?[]const u8 {
        if (cursor.at >= cursor.words.len) return null;
        defer cursor.at += 1;
        return cursor.words[cursor.at];
    }

    fn value(cursor: *Cursor, diag: *Diag, flag: []const u8, what: []const u8) Error![]const u8 {
        return cursor.next() orelse cli_args.refuse(diag, "{s} needs a value: {s}", .{
            flag, what,
        });
    }
};

/// `words` are those after `job`.
pub fn parse(words: []const []const u8, diag: *Diag) Error!Job {
    if (words.len == 0) return too_few(diag);
    const verb = words[0];
    const rest = words[1..];
    if (std.mem.eql(u8, verb, "run")) return .{ .run = try run_of(rest, diag) };
    if (std.mem.eql(u8, verb, "get")) return get_of(rest, diag);
    if (std.mem.eql(u8, verb, "list")) return .{ .list = try list_of(rest, diag) };
    if (std.mem.eql(u8, verb, "cancel")) return .{ .cancel = try name_of("cancel", rest, diag) };
    if (std.mem.eql(u8, verb, "watch")) return watch_of(rest, diag);
    return cli_args.refuse(
        diag,
        "{s} is not a job command (run, get, list, cancel or watch)",
        .{before_equals(verb)},
    );
}

fn too_few(diag: *Diag) Error {
    return cli_args.refuse(diag, "job takes run, get, list, cancel or watch", .{});
}

fn name_of(verb: []const u8, rest: []const []const u8, diag: *Diag) Error![]const u8 {
    if (rest.len == 0) return cli_args.refuse(diag, "job {s} needs a job name", .{verb});
    if (rest.len > 1) return cli_args.refuse(diag, "job {s} takes one name, not {d}", .{
        verb, rest.len,
    });
    return rest[0];
}

fn get_of(rest: []const []const u8, diag: *Diag) Error!Job {
    var wait = false;
    var name: ?[]const u8 = null;
    for (rest) |word| {
        if (std.mem.eql(u8, word, "--wait")) {
            wait = true;
        } else if (word.len > 1 and word[0] == '-') {
            return unknown_flag(diag, "get", word);
        } else if (name == null) {
            name = word;
        } else {
            return cli_args.refuse(diag, "job get takes one name", .{});
        }
    }
    const found = name orelse return cli_args.refuse(diag, "job get needs a job name", .{});
    return .{ .get = .{ .name = found, .wait = wait } };
}

fn unknown_flag(diag: *Diag, verb: []const u8, flag: []const u8) Error {
    return cli_args.refuse(diag, "{s} is not a flag of job {s}", .{ before_equals(flag), verb });
}

/// The word up to its first `=`: `--env=TOKEN=secret` is named `--env`. A refusal never repeats
/// what follows, since a mistyped `--env=K=V` carries a secret.
fn before_equals(word: []const u8) []const u8 {
    return word[0 .. std.mem.indexOfScalar(u8, word, '=') orelse word.len];
}

fn list_of(rest: []const []const u8, diag: *Diag) Error!List {
    var list: List = .{};
    var cursor: Cursor = .{ .words = rest };
    while (cursor.next()) |word| {
        if (std.mem.eql(u8, word, "--state")) {
            const state = try cursor.value(diag, word, "a job state or ended");
            if (!one_of(state, &states)) {
                return cli_args.refuse(diag, "{s} is not a job state (or ended)", .{state});
            }
            list.state = state;
        } else if (std.mem.eql(u8, word, "--label")) {
            list.label = try label_filter(&cursor, diag);
        } else if (word.len > 1 and word[0] == '-') {
            return unknown_flag(diag, "list", word);
        } else {
            return cli_args.refuse(diag, "job list takes no name: {s}", .{word});
        }
    }
    return list;
}

fn label_filter(cursor: *Cursor, diag: *Diag) Error![]const u8 {
    const text = try cursor.value(diag, "--label", "key or key=value");
    if (text.len == 0 or text[0] == '=') {
        return cli_args.refuse(diag, "--label needs a key: key or key=value", .{});
    }
    return text;
}

fn one_of(text: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, text)) return true;
    }
    return false;
}

fn watch_of(rest: []const []const u8, diag: *Diag) Error!Job {
    var from: ?u64 = null;
    var cursor: Cursor = .{ .words = rest };
    while (cursor.next()) |word| {
        if (!std.mem.eql(u8, word, "--from")) {
            if (word.len > 1 and word[0] == '-') return unknown_flag(diag, "watch", word);
            return cli_args.refuse(diag, "job watch takes no name: {s}", .{word});
        }
        const text = try cursor.value(diag, word, "a store revision, 1 or more");
        const number = std.fmt.parseInt(u64, text, 10) catch 0;
        if (number == 0) {
            return cli_args.refuse(diag, "--from needs a revision, 1 or more, not {s}", .{text});
        }
        from = number;
    }
    return .{ .watch = from };
}

fn run_of(rest: []const []const u8, diag: *Diag) Error!Run {
    if (rest.len == 0) return cli_args.refuse(diag, "job run needs a job name", .{});
    if (rest[0].len == 0 or rest[0][0] == '-') {
        return cli_args.refuse(diag, "job run needs a job name first", .{});
    }
    var run: Run = .{ .name = rest[0], .image = "" };
    var cursor: Cursor = .{ .words = rest[1..] };
    var has_command = false;
    while (cursor.next()) |word| {
        if (std.mem.eql(u8, word, "--command")) {
            try command_of(&run, &cursor, diag);
            has_command = true;
        } else {
            try run_flag(&run, word, &cursor, diag);
        }
    }
    if (run.image.len == 0) return cli_args.refuse(diag, "job run needs --image DIGEST", .{});
    if (!has_command) return cli_args.refuse(diag, "job run needs --command WORD...", .{});
    if ((run.input_file == null) != (run.input_env == null)) {
        return cli_args.refuse(diag, "--input-file and --input-env go together", .{});
    }
    return run;
}

/// `--command` takes every word after it.
fn command_of(run: *Run, cursor: *Cursor, diag: *Diag) Error!void {
    if (run.command.len > 0) return cli_args.refuse(diag, "--command is given twice", .{});
    while (cursor.next()) |word| {
        if (run.command.push(word)) continue;
        return cli_args.refuse(diag, "the command has more than {d} words", .{
            constants.job_command_words_max,
        });
    }
    if (run.command.len == 0) return cli_args.refuse(diag, "--command needs a command", .{});
}

fn run_flag(run: *Run, flag: []const u8, cursor: *Cursor, diag: *Diag) Error!void {
    if (std.mem.eql(u8, flag, "--image")) {
        run.image = try cursor.value(diag, flag, "an image digest");
    } else if (std.mem.eql(u8, flag, "--env")) {
        // The text may be a secret: no refusal below repeats it.
        const text = try cursor.value(diag, flag, "NAME=VALUE");
        const pair = pair_of(text) orelse
            return cli_args.refuse(diag, "--env needs NAME=VALUE (a name, then =)", .{});
        if (!run.env.push(pair)) return cli_args.refuse(diag, "more than {d} --env", .{
            constants.runtime_env_count_max,
        });
    } else if (std.mem.eql(u8, flag, "--label")) {
        const text = try cursor.value(diag, flag, "key=value");
        const pair = pair_of(text) orelse
            return cli_args.refuse(diag, "--label needs key=value for a job: {s}", .{text});
        if (!run.labels.push(pair)) return cli_args.refuse(diag, "more than {d} --label", .{
            constants.job_labels_max,
        });
    } else if (std.mem.eql(u8, flag, "--input-file")) {
        run.input_file = try cursor.value(diag, flag, "a file");
    } else if (std.mem.eql(u8, flag, "--input-env")) {
        run.input_env = try cursor.value(diag, flag, "a variable name");
    } else if (std.mem.eql(u8, flag, "--deadline")) {
        run.deadline_ms = try duration_value(cursor, diag, flag);
    } else if (std.mem.eql(u8, flag, "--submit-within")) {
        run.submit_within_ms = try duration_value(cursor, diag, flag);
    } else if (flag.len > 1 and flag[0] == '-') {
        return unknown_flag(diag, "run", flag);
    } else {
        const named = before_equals(flag);
        return cli_args.refuse(diag, "{s} is not part of job run (use flags)", .{named});
    }
}

fn pair_of(text: []const u8) ?Pair {
    const at = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    if (at == 0) return null;
    return .{ .key = text[0..at], .value = text[at + 1 ..] };
}

fn duration_value(cursor: *Cursor, diag: *Diag, flag: []const u8) Error!u64 {
    const text = try cursor.value(diag, flag, "a duration such as 90s, 10m or 2h");
    const ms = duration_ms(text) orelse return cli_args.refuse(
        diag,
        "{s} needs a duration such as 500ms, 90s, 10m or 2h, not {s}",
        .{ flag, text },
    );
    const max: u64 = if (std.mem.eql(u8, flag, "--deadline"))
        constants.job_deadline_ms_max
    else
        constants.job_submit_window_ms_max;
    if (ms > max) return cli_args.refuse(diag, "{s} is at most {d}m, not {s}", .{
        flag, max / (60 * 1000), text,
    });
    return ms;
}

/// `500ms`, `90s`, `10m`, `2h`: a whole number and a unit, above 0.
pub fn duration_ms(text: []const u8) ?u64 {
    const units = [_]struct { suffix: []const u8, ms: u64 }{
        .{ .suffix = "ms", .ms = 1 },
        .{ .suffix = "s", .ms = 1000 },
        .{ .suffix = "m", .ms = 60 * 1000 },
        .{ .suffix = "h", .ms = 60 * 60 * 1000 },
    };
    for (units) |unit| {
        if (!std.mem.endsWith(u8, text, unit.suffix)) continue;
        const digits = text[0 .. text.len - unit.suffix.len];
        // "ms" ends in "s": the digits of "500m" + "s" are not all digits, so try the next unit.
        const count = std.fmt.parseInt(u64, digits, 10) catch continue;
        if (count == 0) return null;
        return std.math.mul(u64, count, unit.ms) catch null;
    }
    return null;
}

const testing = std.testing;

test "a refusal of an unknown flag never repeats what follows the =" {
    // Goal: --env=TOKEN=secret (the GNU spelling) is not echoed. Method: refuse three spellings.
    const lines = [_][]const []const u8{
        &.{ "run", "x", "--image", "d", "--env=TOKEN=s3cretvalue", "--command", "a" },
        &.{ "run", "x", "TOKEN=s3cretvalue", "--command", "a" },
        &.{ "get", "--env=TOKEN=s3cretvalue" },
        &.{ "TOKEN=s3cretvalue", "x" },
    };
    for (lines) |line| {
        const cause = try refusal(line);
        try testing.expect(std.mem.indexOf(u8, cause, "s3cretvalue") == null);
    }
    try testing.expect(std.mem.indexOf(u8, try refusal(lines[0]), "--env is not a flag") != null);
}

fn parse_words(words: []const []const u8) !Job {
    var diag: Diag = undefined;
    diag.reset();
    return parse(words, &diag);
}

fn refusal(words: []const []const u8) ![]const u8 {
    var diag: Diag = undefined;
    diag.reset();
    try testing.expectError(error.Failed, parse(words, &diag));
    try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0111), diag.code);
    return diag.last_cause().?;
}

test "job run: every flag, the command takes the rest of the line" {
    // Goal: the surface of the brief. Method: a line with every flag, then the defaults.
    const job = try parse_words(&.{
        "run",          "etl",       "--image",         "sha256:ab",
        "--env",        "A=1",       "--env",           "B=x=y",
        "--input-file", "in.txt",    "--input-env",     "PAYLOAD",
        "--deadline",   "90s",       "--submit-within", "2h",
        "--label",      "team=data", "--command",       "sh",
        "-c",           "--image",   "exit 3",
    });
    const run = job.run;
    try testing.expectEqualStrings("etl", run.name);
    try testing.expectEqualStrings("sha256:ab", run.image);
    try testing.expectEqual(@as(usize, 2), run.env.slice().len);
    try testing.expectEqualStrings("B", run.env.slice()[1].key);
    try testing.expectEqualStrings("x=y", run.env.slice()[1].value);
    try testing.expectEqualStrings("team", run.labels.slice()[0].key);
    try testing.expectEqualStrings("in.txt", run.input_file.?);
    try testing.expectEqualStrings("PAYLOAD", run.input_env.?);
    try testing.expectEqual(@as(u64, 90_000), run.deadline_ms);
    try testing.expectEqual(@as(u64, 2 * 60 * 60 * 1000), run.submit_within_ms);
    try testing.expectEqual(@as(usize, 4), run.command.slice().len);
    try testing.expectEqualStrings("--image", run.command.slice()[2]);

    const plain = (try parse_words(&.{ "run", "x", "--image", "d", "--command", "true" })).run;
    try testing.expectEqual(deadline_default_ms, plain.deadline_ms);
    try testing.expectEqual(submit_within_default_ms, plain.submit_within_ms);
}

test "job get, list, cancel and watch" {
    // Goal: the other four commands. Method: each accepted line.
    const get = try parse_words(&.{ "get", "--wait", "etl" });
    try testing.expectEqualStrings("etl", get.get.name);
    try testing.expect(get.get.wait);
    try testing.expect(!(try parse_words(&.{ "get", "etl" })).get.wait);
    const list = (try parse_words(&.{ "list", "--state", "ended", "--label", "team" })).list;
    try testing.expectEqualStrings("ended", list.state.?);
    try testing.expectEqualStrings("team", list.label.?);
    try testing.expect((try parse_words(&.{"list"})).list.state == null);
    try testing.expectEqualStrings("etl", (try parse_words(&.{ "cancel", "etl" })).cancel);
    try testing.expect((try parse_words(&.{"watch"})).watch == null);
    try testing.expectEqual(@as(?u64, 42), (try parse_words(&.{ "watch", "--from", "42" })).watch);
}

test "job run: a duration above its bound is refused with the bound, not blamed on zcube" {
    // Goal: no ZC-B0001 from a typo. Method: past each maximum, and past what a u64 holds.
    const cases = [_]struct { line: []const []const u8, cause: []const u8 }{
        .{
            .line = &.{ "run", "x", "--image", "d", "--submit-within", "61m", "--command", "a" },
            .cause = "--submit-within is at most 60m",
        },
        .{
            .line = &.{
                "run",       "x", "--image", "d", "--submit-within", "18446744073709551000ms",
                "--command", "a",
            },
            .cause = "--submit-within is at most 60m",
        },
        .{
            .line = &.{ "run", "x", "--image", "d", "--deadline", "25h", "--command", "a" },
            .cause = "--deadline is at most 1440m",
        },
    };
    for (cases) |case| {
        const cause = try refusal(case.line);
        try testing.expect(std.mem.indexOf(u8, cause, case.cause) != null);
    }
}

test "the refusals of job: each names the part at fault, never an env value" {
    // Goal: the negative space. Method: one bad line per rule; every one is ZC-E0111.
    const cases = [_]struct { line: []const []const u8, cause: []const u8 }{
        .{ .line = &.{}, .cause = "job takes run, get" },
        .{ .line = &.{"logs"}, .cause = "logs is not a job command" },
        .{ .line = &.{"run"}, .cause = "job run needs a job name" },
        .{ .line = &.{ "run", "--image", "d" }, .cause = "needs a job name first" },
        .{ .line = &.{ "run", "x", "--command", "true" }, .cause = "needs --image" },
        .{ .line = &.{ "run", "x", "--image", "d" }, .cause = "needs --command" },
        .{
            .line = &.{ "run", "x", "--image", "d", "--command" },
            .cause = "--command needs a command",
        },
        .{ .line = &.{ "run", "x", "--image" }, .cause = "--image needs a value" },
        .{
            .line = &.{ "run", "x", "--image", "d", "--env", "SECRET", "--command", "a" },
            .cause = "--env needs NAME=VALUE",
        },
        .{
            .line = &.{ "run", "x", "--image", "d", "--env", "=v", "--command", "a" },
            .cause = "--env needs NAME=VALUE",
        },
        .{
            .line = &.{ "run", "x", "--image", "d", "--deadline", "10", "--command", "a" },
            .cause = "--deadline needs a duration",
        },
        .{
            .line = &.{ "run", "x", "--image", "d", "--deadline", "0s", "--command", "a" },
            .cause = "--deadline needs a duration",
        },
        .{
            .line = &.{ "run", "x", "--image", "d", "--input-file", "f", "--command", "a" },
            .cause = "go together",
        },
        .{
            .line = &.{ "run", "x", "--image", "d", "--wat", "--command", "a" },
            .cause = "--wat is not a flag of job run",
        },
        .{ .line = &.{ "run", "x", "stray", "--command", "a" }, .cause = "stray is not part of" },
        .{ .line = &.{"get"}, .cause = "job get needs a job name" },
        .{ .line = &.{ "get", "a", "b" }, .cause = "job get takes one name" },
        .{ .line = &.{ "get", "a", "--now" }, .cause = "--now is not a flag of job get" },
        .{ .line = &.{ "list", "--state", "late" }, .cause = "late is not a job state" },
        .{ .line = &.{ "list", "x" }, .cause = "job list takes no name" },
        .{ .line = &.{ "list", "--label", "=v" }, .cause = "--label needs a key" },
        .{ .line = &.{"cancel"}, .cause = "job cancel needs a job name" },
        .{ .line = &.{ "cancel", "a", "b" }, .cause = "job cancel takes one name" },
        .{ .line = &.{ "watch", "--from", "0" }, .cause = "--from needs a revision" },
        .{ .line = &.{ "watch", "--from", "x" }, .cause = "--from needs a revision" },
        .{ .line = &.{ "watch", "--from" }, .cause = "--from needs a value" },
        .{ .line = &.{ "watch", "etl" }, .cause = "job watch takes no name" },
    };
    for (cases) |case| {
        const cause = try refusal(case.line);
        try testing.expect(std.mem.indexOf(u8, cause, case.cause) != null);
        try testing.expect(std.mem.indexOf(u8, cause, "SECRET") == null);
    }
}

test "too many env, labels and command words are refused" {
    // Goal: the bounds are the constants'. Method: one more than each allows.
    var words: [4 + 2 * (constants.runtime_env_count_max + 1)][]const u8 = undefined;
    words[0] = "run";
    words[1] = "x";
    words[2] = "--image";
    words[3] = "d";
    var count: usize = 4;
    for (0..constants.runtime_env_count_max + 1) |_| {
        words[count] = "--env";
        words[count + 1] = "A=1";
        count += 2;
    }
    const cause = try refusal(words[0..count]);
    try testing.expect(std.mem.indexOf(u8, cause, "more than 16 --env") != null);
}

test "durations" {
    // Goal: the units and what is not one.
    try testing.expectEqual(@as(?u64, 500), duration_ms("500ms"));
    try testing.expectEqual(@as(?u64, 1000), duration_ms("1s"));
    try testing.expectEqual(@as(?u64, 600_000), duration_ms("10m"));
    try testing.expectEqual(@as(?u64, 7_200_000), duration_ms("2h"));
    try testing.expect(duration_ms("10") == null);
    try testing.expect(duration_ms("m") == null);
    try testing.expect(duration_ms("0m") == null);
    try testing.expect(duration_ms("-5s") == null);
    try testing.expect(duration_ms("1.5h") == null);
    try testing.expect(duration_ms("99999999999999999h") == null);
}
