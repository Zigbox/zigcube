//! The command line of `zcube`, parsed into a command and options. Pure: no I/O, so every
//! refusal is a unit test. A refusal is `ZC-E0111` and names the part at fault; the options may
//! come before or after the command (`zcube -v get service`, `zcube get service -v`), as in
//! Zigbox's CLI.
//!
//! ```
//! zcube [options] apply <file.zon>
//! zcube [options] delete service <name>
//! zcube [options] get service|replicas|nodes [name]
//! zcube [options] why service|replica|node <name>
//! zcube [options] explain <code>
//! zcube [options] bundle --last | <kind> <name>
//! zcube [options] check allocations
//! zcube [options] stats pull [node]
//! zcube [options] repair allocations <node> [--confirm]
//! zcube [options] rollout status|pause|resume <service>
//! zcube [options] history <service>
//! zcube [options] local up|down
//! zcube [options] job run|get|list|cancel|watch ...    (src/cli_job_args.zig)
//! ```

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const cli_job_args = @import("cli_job_args.zig");
const cli_rollout = @import("cli_rollout.zig");

const Diag = diag_mod.Diag;

pub const Output = enum { text, wide, json };

/// What `why` and `bundle` can be asked about: the kinds of `GET /v1/why`.
pub const Kind = enum { service, replica, node, job };

pub const Subject = struct { kind: Kind, name: []const u8 };

/// What `get` lists. Nodes arrive with C1.
pub const Listing = enum { service, replicas, nodes };

pub const Options = struct {
    verbose: bool = false,
    output: Output = .text,
    /// `--server HOST:PORT`; null means the environment, then the default.
    server: ?[]const u8 = null,
    yes: bool = false,
    /// apply: show the change and stop.
    dry_run: bool = false,
    no_redact: bool = false,
    /// store accept-rollback, repair allocations: the operator has looked and means it.
    confirm: bool = false,
};

/// `zcube local`: the one command that starts processes (src/cli_local.zig).
pub const LocalAction = enum { up, down };

pub const BundleTarget = union(enum) { last, subject: Subject };

pub const Command = union(enum) {
    apply: []const u8,
    /// `delete service <name>`: the name.
    delete: []const u8,
    get: struct { listing: Listing, name: ?[]const u8 },
    why: Subject,
    explain: []const u8,
    bundle: BundleTarget,
    /// `store accept-rollback --confirm`.
    accept_rollback,
    /// `check allocations`.
    check_allocations,
    /// `stats pull [node]`: the recorded pulls, of one node when it is named.
    stats_pull: ?[]const u8,
    /// `repair allocations <node>`: the node. Without `--confirm` it shows what it would write.
    repair_allocations: []const u8,
    local: LocalAction,
    /// `rollout status|pause|resume <service>`.
    rollout: struct { action: cli_rollout.Action, name: []const u8 },
    /// `history <service>`: the service.
    history: []const u8,
    /// `job run|get|list|cancel|watch`.
    job: cli_job_args.Job,
    help,
    version,
};

pub const Parsed = struct { options: Options, command: Command };

pub const Error = error{Failed};

pub const help_text =
    \\zcube - the Zigcube command line
    \\
    \\usage: zcube [options] <command>
    \\
    \\commands:
    \\  apply <file.zon>             show what a service file would change, then apply it
    \\  delete service <name>        delete a service; its replicas are stopped
    \\  get service [name]           services and how many replicas run
    \\  get replicas [service]       replicas, where they run and how they are doing
    \\  get nodes [name]             nodes, their status, lease, capacity and last contact
    \\  why <kind> <name>            why a service, replica or node is as it is
    \\  explain <code>               explain a diagnostic code offline, for example E0201
    \\  bundle --last                collect the evidence for the last failure
    \\  bundle <kind> <name>         collect the evidence for a service, replica or node
    \\  check allocations            compare each node's accounting with its assignments
    \\  stats pull [node]            the recorded image pulls: bytes by source, time, struck peers
    \\  repair allocations <node>    show the repair of a node's accounting; --confirm writes it
    \\  job run <name> --image <digest> [--env K=V] [--input-file F --input-env VAR]
    \\      [--relay NAME] [--deadline 10m] [--submit-within 10m] [--label k=v]
    \\      --command <word>...
    \\                               run a command in an image once, to its end
    \\  job get <name> [--wait]      a job's state and ending; --wait waits for the ending
    \\  job list [--state S] [--label k=v]
    \\                               jobs, newest names first; S is a state or ended
    \\  job cancel <name>            stop a job
    \\  job watch [--from REV]       one line per ending, as they happen
    \\  rollout status <service>     a service's rollout: phase, progress, deadline and policy
    \\  rollout pause <service>      hold a rollout where it is; nothing new starts or retires
    \\  rollout resume <service>     continue a paused rollout, with a fresh deadline
    \\  history <service>            the stored generations, newest first, and who applied each
    \\  local up                     start a server and an agent on this machine (SQLite)
    \\  local down                   stop them; the state and the containers are kept
    \\  help                         show this text
    \\  version                      print the version
    \\
    \\options (before or after the command):
    \\  -v, --verbose                show the full cause chain of a failure and request ids
    \\  -o, --output text|wide|json  wide adds columns to get; json prints JSON (failures go to
    \\                               stderr, one JSON object per line)
    \\  --server HOST:PORT           where zcube-server listens (default: $ZCUBE_SERVER, then
    \\                               127.0.0.1:7070)
    \\  -y, --yes                    apply, delete: do not ask first (required without a terminal)
    \\  --dry-run                    apply: show the change and stop
    \\  --no-redact                  bundle: keep secrets in the bundle (prints a warning)
    \\
    \\exit codes: 0 ok, 1 your input, 2 your environment, 3 an external service, 70 a bug
    \\  job get --wait: 0 exited with code 0, 10 exited otherwise, 11 failed, 12 cancelled
    \\
;

comptime {
    assert(help_text.len < constants.diag_output_bytes_max);
    assert(help_text[help_text.len - 1] == '\n');
}

/// The options that decide how a refusal is shown, found before the rest is parsed so that a bad
/// argument is reported in the mode the user asked for. Lenient: it reads what it recognises.
pub fn scan(args: []const []const u8) Options {
    assert(args.len <= constants.cli_args_max);
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--") or std.mem.eql(u8, arg, "--command")) break;
        if (is_verbose(arg)) options.verbose = true;
        if (!is_output(arg)) continue;
        if (index + 1 >= args.len) continue;
        if (output_of(args[index + 1])) |output| options.output = output;
    }
    return options;
}

fn is_verbose(arg: []const u8) bool {
    assert(arg.len <= constants.cli_arg_bytes_max);
    return std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose");
}

fn is_output(arg: []const u8) bool {
    assert(arg.len <= constants.cli_arg_bytes_max);
    return std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output");
}

fn output_of(text: []const u8) ?Output {
    return std.meta.stringToEnum(Output, text);
}

/// Parses `args` (without the program name). Initialises `options` first and fills it as it
/// goes, so a failure can still be shown in the mode asked for.
pub fn parse(args: []const []const u8, parsed: *Parsed, diag: *Diag) Error!void {
    assert(diag.code == null);
    if (args.len > constants.cli_args_max) return refuse(diag, "more than {d} arguments", .{
        constants.cli_args_max,
    });
    var positional: [constants.cli_args_max][]const u8 = undefined;
    var count: usize = 0;
    parsed.options = scan(args);
    try split(args, &parsed.options, &positional, &count, diag);
    parsed.command = try command_of(positional[0..count], diag);
    try check_options(&parsed.options, parsed.command, diag);
}

/// Separates the options from the positional words.
fn split(
    args: []const []const u8,
    options: *Options,
    positional: *[constants.cli_args_max][]const u8,
    count: *usize,
    diag: *Diag,
) Error!void {
    var index: usize = 0;
    var only_words = false;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (arg.len > constants.cli_arg_bytes_max) {
            return refuse(diag, "an argument is over {d} bytes", .{constants.cli_arg_bytes_max});
        }
        const is_flag = !only_words and arg.len > 1 and arg[0] == '-';
        if (!is_flag or job_flag(positional[0..count.*], arg)) {
            positional[count.*] = arg;
            count.* += 1;
            if (is_job_command(positional[0..count.*], arg)) only_words = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            only_words = true;
        } else if (is_verbose(arg)) {
            options.verbose = true;
        } else if (is_output(arg)) {
            index += 1;
            options.output = try output_value(args, index, diag);
        } else if (std.mem.eql(u8, arg, "--server")) {
            index += 1;
            if (index >= args.len) return missing_value(diag, "--server", "HOST:PORT");
            options.server = args[index];
        } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            options.yes = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--no-redact")) {
            options.no_redact = true;
        } else if (std.mem.eql(u8, arg, "--confirm")) {
            options.confirm = true;
        } else if (!std.mem.eql(u8, arg, "--last")) {
            return refuse(diag, "{s} is not a flag zcube has", .{arg});
        } else {
            positional[count.*] = arg; // `--last` is a word of `bundle`, kept in order.
            count.* += 1;
        }
    }
}

/// In a job line the flags `zcube` does not have are the job command's, kept as words in order
/// (`cli_job_args.zig`). `--command` ends the options of `zcube`: what follows it is the job's
/// command, whatever it looks like.
fn job_flag(words: []const []const u8, arg: []const u8) bool {
    if (words.len == 0 or !std.mem.eql(u8, words[0], "job")) return false;
    return !is_global(arg);
}

fn is_job_command(words: []const []const u8, arg: []const u8) bool {
    return words.len > 1 and std.mem.eql(u8, words[0], "job") and
        std.mem.eql(u8, arg, "--command");
}

fn is_global(arg: []const u8) bool {
    const names = [_][]const u8{
        "--",        "-v", "--verbose", "-o",        "--output",
        "--server",  "-y", "--yes",     "--dry-run", "--no-redact",
        "--confirm",
    };
    for (names) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn output_value(args: []const []const u8, index: usize, diag: *Diag) Error!Output {
    if (index >= args.len) return missing_value(diag, "--output", "text, wide or json");
    return output_of(args[index]) orelse refuse(diag, "{s} is not an output format", .{
        args[index],
    });
}

fn command_of(words: []const []const u8, diag: *Diag) Error!Command {
    if (words.len == 0) return refuse(diag, "no command was given", .{});
    const name = words[0];
    const rest = words[1..];
    if (std.mem.eql(u8, name, "help")) return no_arguments(diag, name, rest, .help);
    if (std.mem.eql(u8, name, "version")) return no_arguments(diag, name, rest, .version);
    if (std.mem.eql(u8, name, "apply")) return .{
        .apply = try one_argument(diag, name, rest, "a file"),
    };
    if (std.mem.eql(u8, name, "explain")) {
        return .{ .explain = try one_argument(diag, name, rest, "a code") };
    }
    if (std.mem.eql(u8, name, "get")) return get_of(diag, rest);
    if (std.mem.eql(u8, name, "delete")) return delete_of(diag, rest);
    if (std.mem.eql(u8, name, "why")) return .{ .why = try subject_of(diag, name, rest) };
    if (std.mem.eql(u8, name, "bundle")) return bundle_of(diag, rest);
    if (std.mem.eql(u8, name, "check")) {
        if (rest.len == 1 and std.mem.eql(u8, rest[0], "allocations")) return .check_allocations;
        return refuse(diag, "check takes allocations", .{});
    }
    if (std.mem.eql(u8, name, "repair")) return repair_of(diag, rest);
    if (std.mem.eql(u8, name, "stats")) return stats_of(diag, rest);
    if (std.mem.eql(u8, name, "local")) return local_of(diag, rest);
    if (std.mem.eql(u8, name, "rollout")) return rollout_of(diag, rest);
    if (std.mem.eql(u8, name, "history")) return .{
        .history = try one_argument(diag, name, rest, "a service"),
    };
    if (std.mem.eql(u8, name, "job")) return .{ .job = try cli_job_args.parse(rest, diag) };
    if (std.mem.eql(u8, name, "store")) {
        if (rest.len == 1 and std.mem.eql(u8, rest[0], "accept-rollback")) return .accept_rollback;
        return refuse(diag, "store takes accept-rollback", .{});
    }
    return refuse(diag, "{s} is not a zcube command", .{name});
}

fn stats_of(diag: *Diag, rest: []const []const u8) Error!Command {
    const ok = rest.len >= 1 and rest.len <= 2 and std.mem.eql(u8, rest[0], "pull");
    if (!ok) return refuse(diag, "stats takes pull and, optionally, a node: stats pull node1", .{});
    return .{ .stats_pull = if (rest.len == 2) rest[1] else null };
}

fn rollout_of(diag: *Diag, rest: []const []const u8) Error!Command {
    const usage = "rollout takes status, pause or resume and a service: rollout status hello";
    if (rest.len != 2) return refuse(diag, usage, .{});
    const action = std.meta.stringToEnum(cli_rollout.Action, rest[0]) orelse
        return refuse(diag, usage, .{});
    return .{ .rollout = .{ .action = action, .name = rest[1] } };
}

fn repair_of(diag: *Diag, rest: []const []const u8) Error!Command {
    if (rest.len != 2 or !std.mem.eql(u8, rest[0], "allocations")) {
        return refuse(diag, "repair needs allocations and a node: repair allocations node1", .{});
    }
    return .{ .repair_allocations = rest[1] };
}

fn no_arguments(
    diag: *Diag,
    name: []const u8,
    rest: []const []const u8,
    command: Command,
) Error!Command {
    if (rest.len > 0) return refuse(diag, "{s} takes no arguments", .{name});
    return command;
}

fn one_argument(
    diag: *Diag,
    name: []const u8,
    rest: []const []const u8,
    what: []const u8,
) Error![]const u8 {
    if (rest.len == 0) return refuse(diag, "{s} needs {s}", .{ name, what });
    if (rest.len > 1) return refuse(diag, "{s} takes one argument, not {d}", .{ name, rest.len });
    return rest[0];
}

fn local_of(diag: *Diag, rest: []const []const u8) Error!Command {
    if (rest.len == 1) {
        if (std.mem.eql(u8, rest[0], "up")) return .{ .local = .up };
        if (std.mem.eql(u8, rest[0], "down")) return .{ .local = .down };
    }
    return refuse(diag, "local takes up or down", .{});
}

fn get_of(diag: *Diag, rest: []const []const u8) Error!Command {
    if (rest.len == 0) {
        return refuse(diag, "get needs what to list: service, replicas or nodes", .{});
    }
    if (rest.len > 2) return refuse(diag, "get takes a kind and at most one name", .{});
    const word = rest[0];
    const listing: Listing = if (std.mem.eql(u8, word, "service") or std.mem.eql(
        u8,
        word,
        "services",
    ))
        .service
    else if (std.mem.eql(u8, word, "replicas") or std.mem.eql(u8, word, "replica"))
        .replicas
    else if (std.mem.eql(u8, word, "nodes") or std.mem.eql(u8, word, "node"))
        .nodes
    else
        return refuse(
            diag,
            "{s} is not something get lists (service, replicas or nodes)",
            .{word},
        );
    return .{ .get = .{ .listing = listing, .name = if (rest.len == 2) rest[1] else null } };
}

fn delete_of(diag: *Diag, rest: []const []const u8) Error!Command {
    if (rest.len != 2) return refuse(
        diag,
        "delete needs a kind and a name: delete service hello",
        .{},
    );
    if (!std.mem.eql(u8, rest[0], "service")) {
        return refuse(diag, "{s} is not something delete removes (service)", .{rest[0]});
    }
    return .{ .delete = rest[1] };
}

fn kind_of(word: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, word);
}

fn subject_of(diag: *Diag, name: []const u8, rest: []const []const u8) Error!Subject {
    if (rest.len != 2) return refuse(
        diag,
        "{s} needs a kind and a name: {s} service hello",
        .{ name, name },
    );
    const kind = kind_of(rest[0]) orelse
        return refuse(diag, "{s} is not a kind (service, replica or node)", .{rest[0]});
    return .{ .kind = kind, .name = rest[1] };
}

fn bundle_of(diag: *Diag, rest: []const []const u8) Error!Command {
    if (rest.len == 1 and std.mem.eql(u8, rest[0], "--last")) return .{ .bundle = .last };
    if (rest.len == 0) return refuse(diag, "bundle needs --last, or a kind and a name", .{});
    for (rest) |word| {
        if (std.mem.eql(u8, word, "--last")) {
            return refuse(diag, "bundle takes --last or a kind and a name, not both", .{});
        }
    }
    return .{ .bundle = .{ .subject = try subject_of(diag, "bundle", rest) } };
}

/// A flag that belongs to one command is refused with the others.
fn check_options(options: *const Options, command: Command, diag: *Diag) Error!void {
    if (options.yes and command != .apply and command != .delete) {
        return refuse(diag, "--yes is for zcube apply and delete", .{});
    }
    if (command == .accept_rollback and !options.confirm) {
        return refuse(diag, "accepting a store that went backwards needs --confirm", .{});
    }
    if (options.confirm and command != .accept_rollback and command != .repair_allocations) {
        return refuse(diag, "--confirm is for zcube store accept-rollback and repair", .{});
    }
    if (options.dry_run and command != .apply) {
        return refuse(diag, "--dry-run is for zcube apply", .{});
    }
    if (options.no_redact and command != .bundle) {
        return refuse(diag, "--no-redact is for zcube bundle", .{});
    }
    if (options.output == .wide and !takes_wide(command)) {
        return refuse(diag, "--output wide is for zcube get, stats pull and job list", .{});
    }
}

fn takes_wide(command: Command) bool {
    return switch (command) {
        .get, .stats_pull => true,
        .job => |job| job == .list,
        else => false,
    };
}

fn missing_value(diag: *Diag, flag: []const u8, what: []const u8) Error {
    return refuse(diag, "{s} needs a value: {s}", .{ flag, what });
}

/// `ZC-E0111` with the one fix that always applies.
pub fn refuse(diag: *Diag, comptime format: []const u8, args: anytype) Error {
    assert(diag.code == null);
    diag.raise(.E0111);
    diag.while_("reading the command line", .{});
    diag.cause(format, args);
    diag.fix(.{ .sentence = "see the commands and flags:", .command = "zcube help" });
    return error.Failed;
}

const testing = std.testing;

fn parse_text(line: []const []const u8) !Parsed {
    var diag: Diag = undefined;
    diag.reset();
    var parsed: Parsed = undefined;
    parse(line, &parsed, &diag) catch |err| {
        try testing.expectEqual(error.Failed, err);
        try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0111), diag.code);
        return err;
    };
    return parsed;
}

test "the commands of the handoff parse, with options before or after" {
    // Goal: the surface HANDOFF names. Method: each command line, options in both places.
    const apply = try parse_text(&.{ "apply", "hello.zon", "--yes", "-v" });
    try testing.expectEqualStrings("hello.zon", apply.command.apply);
    try testing.expect(apply.options.yes);
    try testing.expect(apply.options.verbose);

    const get = try parse_text(&.{ "-o", "wide", "get", "replicas", "hello" });
    try testing.expectEqual(Listing.replicas, get.command.get.listing);
    try testing.expectEqualStrings("hello", get.command.get.name.?);
    try testing.expectEqual(Output.wide, get.options.output);

    const why = try parse_text(&.{ "why", "service", "broken", "--output", "json" });
    try testing.expectEqual(Kind.service, why.command.why.kind);
    try testing.expectEqual(Output.json, why.options.output);

    const bundle = try parse_text(&.{ "bundle", "--last", "--no-redact" });
    try testing.expect(bundle.command.bundle == .last);
    try testing.expect(bundle.options.no_redact);
    const named = try parse_text(&.{ "bundle", "replica", "hello-1", "--server", "10.0.0.1:7070" });
    try testing.expectEqualStrings("hello-1", named.command.bundle.subject.name);
    try testing.expectEqualStrings("10.0.0.1:7070", named.options.server.?);

    const delete = try parse_text(&.{ "delete", "service", "hello", "-y" });
    try testing.expectEqualStrings("hello", delete.command.delete);
    const explain = try parse_text(&.{ "explain", "ZC-E0201" });
    try testing.expectEqualStrings("ZC-E0201", explain.command.explain);
    _ = try parse_text(&.{"help"});
    try testing.expectEqual(LocalAction.up, (try parse_text(&.{ "local", "up" })).command.local);
    const verbose_down = try parse_text(&.{ "-v", "local", "down" });
    try testing.expectEqual(LocalAction.down, verbose_down.command.local);
}

test "the refusals: each names the part at fault" {
    // Goal: the negative space of the grammar. Method: one bad line per rule; every one is
    // ZC-E0111 (parse_text checks that) and the cause names the part.
    const cases = [_]struct { line: []const []const u8, cause: []const u8 }{
        .{ .line = &.{}, .cause = "no command was given" },
        .{ .line = &.{"frobnicate"}, .cause = "frobnicate is not a zcube command" },
        .{ .line = &.{ "apply", "--bogus" }, .cause = "--bogus is not a flag zcube has" },
        .{ .line = &.{"apply"}, .cause = "apply needs a file" },
        .{ .line = &.{ "apply", "a", "b" }, .cause = "apply takes one argument, not 2" },
        .{ .line = &.{ "get", "pods" }, .cause = "pods is not something get lists" },
        .{ .line = &.{"get"}, .cause = "get needs what to list" },
        .{ .line = &.{ "why", "service" }, .cause = "why needs a kind and a name" },
        .{ .line = &.{ "why", "pod", "x" }, .cause = "pod is not a kind" },
        .{ .line = &.{"bundle"}, .cause = "bundle needs --last" },
        .{ .line = &.{ "bundle", "--last", "service", "x" }, .cause = "not both" },
        .{ .line = &.{ "get", "service", "-o" }, .cause = "--output needs a value" },
        .{ .line = &.{ "get", "service", "-o", "xml" }, .cause = "xml is not an output format" },
        .{ .line = &.{ "get", "--server" }, .cause = "--server needs a value" },
        .{
            .line = &.{ "get", "service", "--yes" },
            .cause = "--yes is for zcube apply and delete",
        },
        .{ .line = &.{ "get", "service", "--dry-run" }, .cause = "--dry-run is for zcube apply" },
        .{
            .line = &.{ "why", "service", "x", "--no-redact" },
            .cause = "--no-redact is for zcube bundle",
        },
        .{
            .line = &.{ "why", "service", "x", "-o", "wide" },
            .cause = "--output wide is for zcube get",
        },
        .{ .line = &.{ "help", "me" }, .cause = "help takes no arguments" },
        .{ .line = &.{"local"}, .cause = "local takes up or down" },
        .{ .line = &.{ "local", "restart" }, .cause = "local takes up or down" },
        .{ .line = &.{ "local", "up", "down" }, .cause = "local takes up or down" },
        .{
            .line = &.{ "delete", "replica", "x" },
            .cause = "replica is not something delete removes",
        },
        .{ .line = &.{ "delete", "service" }, .cause = "delete needs a kind and a name" },
    };
    for (cases) |case| {
        var diag: Diag = undefined;
        diag.reset();
        var parsed: Parsed = undefined;
        try testing.expectError(error.Failed, parse(case.line, &parsed, &diag));
        const found = diag.last_cause().?;
        try testing.expect(std.mem.indexOf(u8, found, case.cause) != null);
    }
}

test "scan finds the output mode before a bad argument is reached" {
    // Goal: a refusal is rendered in the mode the user asked for, wherever the flags are.
    const options = scan(&.{ "frobnicate", "--output", "json", "-v" });
    try testing.expectEqual(Output.json, options.output);
    try testing.expect(options.verbose);
    try testing.expectEqual(Output.text, scan(&.{ "--", "-o", "json" }).output);
}

test "stats pull takes an optional node, and nothing else" {
    // Goal: the slice 7 surface. Method: the accepted lines, then one refusal per rule.
    const all = try parse_text(&.{ "stats", "pull" });
    try testing.expect(all.command.stats_pull == null);
    const one = try parse_text(&.{ "stats", "pull", "node2", "-o", "wide" });
    try testing.expectEqualStrings("node2", one.command.stats_pull.?);
    const lines = [_][]const []const u8{
        &.{"stats"}, &.{ "stats", "push" }, &.{ "stats", "pull", "a", "b" },
    };
    for (lines) |line| {
        var diag: Diag = undefined;
        diag.reset();
        var parsed: Parsed = undefined;
        try testing.expectError(error.Failed, parse(line, &parsed, &diag));
        try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "stats takes pull") != null);
    }
}

test "a lone dash and words after -- are positional" {
    // Goal: a file called -x.zon is reachable. Method: after `--` everything is a word.
    const parsed = try parse_text(&.{ "apply", "--", "-x.zon" });
    try testing.expectEqualStrings("-x.zon", parsed.command.apply);
}

test "check and repair allocations, and --confirm for repair only" {
    // Goal: the slice 4d surface. Method: the accepted lines, then one refusal per rule.
    const check = try parse_text(&.{ "check", "allocations", "-o", "json" });
    try testing.expect(check.command == .check_allocations);
    const shown = try parse_text(&.{ "repair", "allocations", "node1" });
    try testing.expectEqualStrings("node1", shown.command.repair_allocations);
    try testing.expect(!shown.options.confirm);
    const confirmed = try parse_text(&.{ "repair", "allocations", "node1", "--confirm" });
    try testing.expect(confirmed.options.confirm);
    const cases = [_]struct { line: []const []const u8, cause: []const u8 }{
        .{ .line = &.{"check"}, .cause = "check takes allocations" },
        .{ .line = &.{ "check", "nodes" }, .cause = "check takes allocations" },
        .{ .line = &.{ "repair", "allocations" }, .cause = "repair needs allocations and a node" },
        .{ .line = &.{ "repair", "node1" }, .cause = "repair needs allocations and a node" },
        .{
            .line = &.{ "check", "allocations", "--confirm" },
            .cause = "--confirm is for zcube store accept-rollback and repair",
        },
        .{
            .line = &.{ "check", "allocations", "-o", "wide" },
            .cause = "--output wide is for zcube get",
        },
    };
    for (cases) |case| {
        var diag: Diag = undefined;
        diag.reset();
        var parsed: Parsed = undefined;
        try testing.expectError(error.Failed, parse(case.line, &parsed, &diag));
        try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, case.cause) != null);
    }
}

test "rollout takes status, pause or resume and a service; history takes a service" {
    // Goal: the C3 slice 11 surface. Method: the accepted lines, then one refusal per rule.
    const status = try parse_text(&.{ "rollout", "status", "hello" });
    try testing.expectEqual(cli_rollout.Action.status, status.command.rollout.action);
    try testing.expectEqualStrings("hello", status.command.rollout.name);
    const pause = try parse_text(&.{ "rollout", "pause", "hello", "-o", "json" });
    try testing.expectEqual(cli_rollout.Action.pause, pause.command.rollout.action);
    const history = try parse_text(&.{ "history", "hello" });
    try testing.expectEqualStrings("hello", history.command.history);
    const lines = [_][]const []const u8{
        &.{"rollout"},                                &.{ "rollout", "stop", "hello" },
        &.{ "rollout", "status" },                    &.{ "rollout", "pause", "a", "b" },
        &.{"history"},                                &.{ "history", "a", "b" },
        &.{ "rollout", "status", "a", "-o", "wide" },
    };
    for (lines) |line| {
        var diag: Diag = undefined;
        diag.reset();
        var parsed: Parsed = undefined;
        try testing.expectError(error.Failed, parse(line, &parsed, &diag));
        try testing.expect(diag.last_cause() != null);
    }
}
