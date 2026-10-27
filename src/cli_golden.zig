//! Golden tests for diagnostics (DIAGNOSTICS.md, "Testing"): for every registered `ZC-` code, one
//! case triggers the condition through the real command line and compares the default, verbose and
//! JSON output with the checked-in files in `src/testdata/cli/`. A change to a message is a change
//! to a golden file in the same commit; `ZCUBE_GOLDEN_UPDATE=<absolute path of that directory>`
//! writes the files instead of comparing, and the diff is the review.
//!
//! Two kinds of case. A *raised* case is a condition of the command line itself (a bad flag, a
//! file that isn't a service, a server that isn't there): the command is run for real. A *relayed*
//! case is a diagnostic that the server, its store or the runtime raises; the server is a canned
//! reply (`Env.transport`), and the golden pins how the command line shows it, the same for
//! every code (DIAGNOSTICS.md principle 6). The producers' own conditions are tested where they
//! are raised (the store conformance suite, the API and controller tests).
//!
//! The second test runs every case in every mode and fails if any output shows a stack trace, a
//! source location, an address or a raw Zig error name. The files are named by the code's tag:
//! E0102.txt, E0102.verbose.txt, E0102.json.txt.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const cli = @import("cli.zig");
const cli_env = @import("cli_env.zig");
const cli_report = @import("cli_report.zig");
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Style = enum { text, verbose, json };

/// A canned reply to one request.
const Canned = struct { status: u16, body: []const u8 };

const Route = *const fn (path: []const u8) ?Canned;

const Script = union(enum) {
    /// No transport: the real connect, to a port nobody listens on.
    closed_port,
    /// Every request is answered with this diagnostic.
    diagnostic: Builder,
    /// Each request is answered by looking at its path.
    router: Route,
};

const Case = struct {
    code: codes.Code,
    /// The arguments after the program name, without the flags of the style.
    args: []const []const u8,
    script: Script,
    flags: Flags = .{},
    /// The command shows something on standard output before it fails (the change, for apply).
    prints: bool = false,
};

// ---- Canned replies ----------------------------------------------------------------------------

const empty_list = Canned{ .status = 200, .body = "{\"revision\":1,\"kvs\":[],\"continue\":null}" };
const status_ok = Canned{
    .status = 200,
    .body = "{\"server\":{\"version\":\"0.0.0\",\"started_at_ms\":1},\"time_ms\":2," ++
        "\"store\":{\"backend\":\"sqlite\",\"ok\":true,\"revision\":1,\"compacted_revision\":0}}",
};
const dry_run_update = Canned{
    .status = 200,
    .body = "{\"request_id\":\"r-0000001\",\"dry_run\":true,\"action\":\"update\"," ++
        "\"name\":\"hello\",\"generation\":1,\"change\":\"replicas 3 \\u2192 5\"}",
};

fn route_empty(path: []const u8) ?Canned {
    if (std.mem.startsWith(u8, path, "/v1/status")) return status_ok;
    return empty_list;
}

fn route_not_json(path: []const u8) ?Canned {
    _ = path;
    return .{ .status = 200, .body = "<html>welcome to nginx</html>" };
}

fn route_dry_run(path: []const u8) ?Canned {
    _ = path;
    return dry_run_update;
}

// ---- Relayed diagnostics -----------------------------------------------------------------------
//
// What the server, its store, the controllers and the runtime say, in the words of their code
// (the file named after each function is where the words come from).

const Builder = *const fn (diag: *diag_mod.Diag) void;

/// A diagnostic of `code` with these causes (the real one last) and one fix.
fn sample(
    diag: *diag_mod.Diag,
    code: codes.Code,
    causes: []const []const u8,
    sentence: []const u8,
) void {
    diag.raise(code);
    for (causes) |cause| diag.cause("{s}", .{cause});
    diag.fix(.{ .sentence = sentence });
}

fn conflict(diag: *diag_mod.Diag) void { // api.zig
    diag.raise(.E0105);
    diag.cause("service hello was changed by someone else during the request", .{});
    const sentence = "look at it as it is now, then apply again";
    diag.fix_with(sentence, "zcube get service {s}", .{"hello"});
}

fn bad_request(diag: *diag_mod.Diag) void { // api.zig
    diag.raise(.E0104);
    diag.while_("reading the request", .{});
    diag.cause("applied_by must be 1 to 64 bytes", .{});
    diag.fix(.{ .sentence = "see docs/api.md for the parameters of each endpoint" });
}

fn bad_config(diag: *diag_mod.Diag) void { // server_config.zig
    const cause = "the store is nosql:x; it must be memory, sqlite:<path> or postgres:<settings>";
    sample(diag, .E0106, &.{cause}, "name a store zcube-server supports");
}

fn cannot_listen(diag: *diag_mod.Diag) void { // server.zig
    const cause = "can't listen on 127.0.0.1:7070: another process is already listening on it";
    sample(diag, .E0107, &.{cause}, "listen on another port");
    diag.fix(.{ .sentence = "or stop the other process", .command = "ss -ltnp | grep 7070" });
}

fn at_limit(diag: *diag_mod.Diag) void { // server.zig
    const sentence = "raise the process's thread limit (ulimit -u) and start it again";
    sample(diag, .E0108, &.{"the server could not start a thread for its work"}, sentence);
}

fn store_down(diag: *diag_mod.Diag) void { // sim_world.zig, pq.zig
    diag.raise(.E0201);
    diag.while_("reading desired state for the request", .{});
    diag.cause("libpq reported: connection to server at \"127.0.0.1\", port 5432 failed: " ++
        "Connection refused", .{});
    diag.cause("the Postgres server at 127.0.0.1 port 5432 did not accept a connection", .{});
    diag.fix(.{ .sentence = "start Postgres, or correct the host and port in the store settings" });
    diag.fix_with("check that it is accepting connections", "pg_isready -h {s} -p {s}", .{
        "127.0.0.1", "5432",
    });
    diag.context("store", "postgres", .{});
}

fn store_failed(diag: *diag_mod.Diag) void { // store_sqlite.zig
    sample(diag, .E0202, &.{
        "SQLite reported: database or disk is full (result code 13)",
        "the disk holding the store file is full",
    }, "fix that condition, then retry; nothing was changed");
    diag.context("path", "/var/lib/zcube/store.db", .{});
}

fn compacted(diag: *diag_mod.Diag) void { // store_failures.zig
    assert(failures.compacted(diag, 10, 380) == error.Compacted);
}

fn future(diag: *diag_mod.Diag) void { // store_failures.zig
    assert(failures.future_read(diag, 9000, 412) == error.FutureRevision);
}

fn lease_gone(diag: *diag_mod.Diag) void { // store_failures.zig
    assert(failures.lease_not_found(diag, 43) == error.LeaseNotFound);
}

fn too_large(diag: *diag_mod.Diag) void { // store.zig
    const cause = "a value is 300000 bytes; the limit is 262144";
    const sentence = "store large data outside the control plane and keep a reference";
    sample(diag, .E0206, &.{cause}, sentence);
}

fn no_capacity(diag: *diag_mod.Diag) void { // store_failures.zig
    assert(failures.watch_slots_full(diag) == error.NoCapacity);
}

fn store_busy(diag: *diag_mod.Diag) void { // store_sqlite.zig
    sample(diag, .E0208, &.{
        "SQLite reported: database is locked (result code 5)",
        "another connection held the write lock for over 5000 ms",
    }, "stop whatever else uses the store file, then retry");
    diag.context("path", "/var/lib/zcube/store.db", .{});
}

fn store_damaged(diag: *diag_mod.Diag) void { // store_sqlite.zig
    sample(diag, .E0209, &.{
        "SQLite reported: file is not a database (result code 26)",
        "the store file is damaged or is not a zcube store",
    }, "restore the file from a backup, or use another path");
    diag.context("path", "/var/lib/zcube/store.db", .{});
}

fn store_too_new(diag: *diag_mod.Diag) void { // store_sqlite.zig
    const cause = "the store file has schema version 3; this zcube understands up to 2";
    const sentence = "run the zcube version that created the file, or upgrade zcube";
    sample(diag, .E0210, &.{cause}, sentence);
    diag.context("path", "/var/lib/zcube/store.db", .{});
}

fn store_credentials(diag: *diag_mod.Diag) void { // pq.zig
    sample(diag, .E0211, &.{
        "libpq reported: password authentication failed for user \"zcube\"",
        "Postgres at 127.0.0.1 did not let the role zcube in",
    }, "correct the user and password in the store settings");
    diag.context("user", "zcube", .{});
}

fn store_no_database(diag: *diag_mod.Diag) void { // pq.zig
    sample(diag, .E0212, &.{
        "libpq reported: database \"zcube\" does not exist",
        "Postgres at 127.0.0.1 has no database named zcube",
    }, "create the database, or correct its name in the store settings");
    diag.context("db", "zcube", .{});
}

fn store_dropped(diag: *diag_mod.Diag) void { // pq.zig
    sample(diag, .E0213, &.{
        "libpq reported: server closed the connection unexpectedly",
        "the connection to Postgres dropped; nothing was changed",
    }, "retry the command; zcube reconnects before the next operation");
}

fn bad_record(diag: *diag_mod.Diag) void { // records.zig
    const cause = "the value at /services/old is not a valid service record";
    sample(diag, .E0301, &.{cause}, "fix or delete that key; the next pass tries again");
}

fn too_many(diag: *diag_mod.Diag) void { // controller.zig
    const cause = "more than 512 records under /replicas/";
    sample(diag, .E0302, &.{cause}, "delete what is no longer needed");
}

fn unknown_container(diag: *diag_mod.Diag) void { // runtime.zig
    const sentence = "list what the runtime knows, then retry";
    sample(diag, .E0501, &.{"no container by that name"}, sentence);
}

fn runtime_failed(diag: *diag_mod.Diag) void { // runtime.zig
    const cause = "the runtime refused to start the process";
    sample(diag, .E0502, &.{cause}, "check the node's runtime, then retry");
}

fn agent_unreachable(diag: *diag_mod.Diag) void { // agent_http.zig
    sample(
        diag,
        .E0503,
        &.{"no answer from zcube-server at 127.0.0.1:7070: the connection was refused"},
        "start the server, or give the agent the address it listens on",
    );
}

fn agent_refused(diag: *diag_mod.Diag) void { // agent_remote.zig
    sample(diag, .E0504, &.{
        "zcube-server answered 400: the request can't be understood (ZC-E0104)",
        "body: is not what this endpoint takes: see docs/api.md",
    }, "look at the server's log for this request, or restart the server");
}

fn agent_config(diag: *diag_mod.Diag) void { // agent_config.zig
    sample(diag, .E0505, &.{"the node has no name"}, "give --node, or .node in the file");
}

fn agent_state_dir(diag: *diag_mod.Diag) void { // fake_runtime.zig
    sample(
        diag,
        .E0506,
        &.{"another agent is using the state directory /var/lib/zcube-agent"},
        "give each agent a state directory of its own",
    );
}

fn agent_supervisor(diag: *diag_mod.Diag) void { // fake_runtime.zig
    sample(
        diag,
        .E0507,
        &.{"the host refused to start a supervisor for hello-1"},
        "free process slots on the node, or restart the agent",
    );
}

fn agent_command(diag: *diag_mod.Diag) void { // fake_supervisor.zig
    sample(
        diag,
        .E0508,
        &.{"the command was not found on this node"},
        "check the command in the service file, then apply it again",
    );
}

fn agent_lost(diag: *diag_mod.Diag) void { // fake_runtime.zig
    sample(
        diag,
        .E0509,
        &.{"the supervisor of hello-1 ended without writing how the command ended"},
        "look for something killing zcube-agent processes on this node",
    );
}

fn agent_lease(diag: *diag_mod.Diag) void { // agent_run.zig
    sample(
        diag,
        .W0501,
        &.{"lease 4 ended; node node1 registered again on lease 5"},
        "if this repeats, check the network between the agent and the server",
    );
}

/// A bug the server reports (it has written its own bundle, on its own machine).
fn server_bug(diag: *diag_mod.Diag) void { // store_postgres.zig
    diag.raise(.B0001);
    diag.cause("the store log has a hole between revisions 41 and 44", .{});
    diag.cause("a watch read the log again 3 times and the revision stayed missing", .{});
}

// ---- The cases ---------------------------------------------------------------------------------

const get_service: []const []const u8 = &.{ "get", "service" };
const hello_file = "src/testdata/cli/hello.zon";
const apply_hello: []const []const u8 = &.{ "apply", hello_file };
const apply_yes: []const []const u8 = &.{ "apply", hello_file, "--yes" };

/// A condition the server's side raises: any request is answered with it.
fn relayed(code: codes.Code, build: Builder) Case {
    return .{ .code = code, .args = get_service, .script = .{ .diagnostic = build } };
}

/// A condition of the command line itself, run for real against a server that is not there.
fn raised(code: codes.Code, args: []const []const u8) Case {
    return .{ .code = code, .args = args, .script = .closed_port };
}

/// A command line against a server that answers by looking at the path.
fn routed(code: codes.Code, args: []const []const u8, route: Route) Case {
    return .{ .code = code, .args = args, .script = .{ .router = route } };
}

const cases = [_]Case{
    routed(.E0101, &.{ "get", "service", "nosuch" }, route_empty),
    raised(.E0102, get_service),
    routed(.E0103, get_service, route_not_json),
    relayed(.E0104, bad_request),
    .{ .code = .E0105, .args = apply_yes, .script = .{ .diagnostic = conflict } },
    relayed(.E0106, bad_config),
    relayed(.E0107, cannot_listen),
    relayed(.E0108, at_limit),
    raised(.E0109, &.{ "apply", "src/testdata/cli/missing.zon" }),
    raised(.E0110, &.{ "apply", "src/testdata/cli/typo.zon" }),
    raised(.E0111, &.{"frobnicate"}),
    raised(.E0112, &.{ "--server", "nonsense", "get", "service" }),
    with_dry_run(.E0113, .{}),
    with_dry_run(.E0114, .{ .stdin_terminal = true, .stdin_text = "n\n" }),
    with_flags(raised(.E0115, &.{"help"}), .{ .stdout_full = true }),
    with_flags(routed(.E0116, bundle_hello, route_empty), .{ .no_state = true }),
    with_flags(routed(.E0117, &.{ "bundle", "--last" }, route_empty), .{ .missing_state = true }),
    raised(.E0118, &.{ "explain", "nope" }),
    with_flags(routed(.W0119, bundle_unredacted, route_empty), .{ .warning = true }),
    with_flags(raised(.E0120, &.{ "explain", "E0102" }), .{ .no_memory = true }),
    relayed(.E0201, store_down),
    relayed(.E0202, store_failed),
    relayed(.E0203, compacted),
    relayed(.E0204, future),
    relayed(.E0205, lease_gone),
    relayed(.E0206, too_large),
    relayed(.E0207, no_capacity),
    relayed(.E0208, store_busy),
    relayed(.E0209, store_damaged),
    relayed(.E0210, store_too_new),
    relayed(.E0211, store_credentials),
    relayed(.E0212, store_no_database),
    relayed(.E0213, store_dropped),
    relayed(.E0301, bad_record),
    relayed(.E0302, too_many),
    relayed(.E0501, unknown_container),
    relayed(.E0502, runtime_failed),
    relayed(.E0503, agent_unreachable),
    relayed(.E0504, agent_refused),
    relayed(.E0505, agent_config),
    relayed(.E0506, agent_state_dir),
    relayed(.E0507, agent_supervisor),
    relayed(.E0508, agent_command),
    relayed(.E0509, agent_lost),
    relayed(.W0501, agent_lease),
    with_flags(routed(.B0002, get_service, route_empty), .{ .silent_failure = true }),
};

const bundle_hello: []const []const u8 = &.{ "bundle", "service", "hello" };
const bundle_unredacted: []const []const u8 = &.{ "bundle", "service", "hello", "--no-redact" };

/// The flags of a case that change its environment, not its arguments.
const Flags = struct {
    /// The environment has no state directory.
    no_state: bool = false,
    /// The state directory is one that does not exist.
    missing_state: bool = false,
    stdin_terminal: bool = false,
    stdin_text: []const u8 = "",
    /// Standard output fails every write, as `> /dev/full` does.
    stdout_full: bool = false,
    /// Every request for memory is refused.
    no_memory: bool = false,
    /// A command that fails without saying why (a bug in the command).
    silent_failure: bool = false,
    /// The case succeeds with a warning: the exit code is the command's, not the blame's.
    warning: bool = false,
};

fn with_flags(base: Case, flags: Flags) Case {
    var case = base;
    case.flags = flags;
    return case;
}

/// An apply of the file that changes `hello`, which the dry run reports and the user answers.
fn with_dry_run(code: codes.Code, flags: Flags) Case {
    var case = with_flags(routed(code, apply_hello, route_dry_run), flags);
    case.prints = true;
    return case;
}

// ---- Running a case ----------------------------------------------------------------------------

/// What a run of the command line produced.
const Output = struct {
    exit: u8,
    stdout: []const u8,
    stderr: []const u8,
};

const Fixture = struct {
    arena: Allocator,
    script: Script,
};

fn http(arena: Allocator, canned: Canned) []const u8 {
    const format = "HTTP/1.1 {d} Reply\r\nContent-Length: {d}\r\n" ++
        "X-Request-Id: r-0000001\r\n\r\n{s}";
    const args = .{ canned.status, canned.body.len, canned.body };
    return std.fmt.allocPrint(arena, format, args) catch unreachable; // The test arena has room.
}

/// The reply a server sends for a diagnostic: the body of docs/api.md, "Errors".
fn diagnostic_reply(arena: Allocator, build: *const fn (*diag_mod.Diag) void) []const u8 {
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    build(&diag);
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &diag);
    var line: [constants.diag_output_bytes_max]u8 = undefined;
    var writer = Writer.fixed(&line);
    // A diagnostic fits its buffer, and the test arena has room.
    zigbox.diagnostic.write_json(&writer, &diagnostic) catch unreachable;
    const format = "{{\"request_id\":\"r-0000001\",\"diagnostics\":[{s}]}}";
    const json = std.mem.trimEnd(u8, writer.buffered(), "\n");
    const body = std.fmt.allocPrint(arena, format, .{json}) catch unreachable; // Same.
    const status: u16 = switch (diagnostic.blame) {
        .user => 400,
        .environment => 503,
        .external => 502,
        .internal => 500,
    };
    return http(arena, .{ .status = status, .body = body });
}

fn exchange(
    context: *anyopaque,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) ?[]const u8 {
    _ = method;
    _ = body;
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    return switch (fixture.script) {
        .closed_port => null,
        .diagnostic => |build| diagnostic_reply(fixture.arena, build),
        .router => |route| if (route(path)) |canned| http(fixture.arena, canned) else null,
    };
}

fn drain_fails(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    _ = w;
    _ = data;
    _ = splat;
    return error.WriteFailed;
}

fn refuse_alloc(
    context: *anyopaque,
    length: usize,
    alignment: std.mem.Alignment,
    address: usize,
) ?[*]u8 {
    _ = context;
    _ = length;
    _ = alignment;
    _ = address;
    return null;
}

const refusing_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = refuse_alloc,
        .resize = Allocator.noResize,
        .remap = Allocator.noRemap,
        .free = Allocator.noFree,
    },
};

fn silent_executor(
    env: *const cli_env.Env,
    client: *@import("cli_http.zig").Client,
    parsed: *const @import("cli_args.zig").Parsed,
    line: []const u8,
    report: *cli_report.Report,
) cli_report.Error!void {
    _ = env;
    _ = client;
    _ = parsed;
    _ = line;
    _ = report;
    return error.Failed;
}

const Directory = struct {
    tmp: testing.TmpDir,
    /// The state directory of the run, absolute.
    state: []const u8,
};

fn run_case(arena: Allocator, case: *const Case, style: Style, state_root: []const u8) !Output {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, case.args);
    switch (style) {
        .text => {},
        .verbose => try args.append(arena, "-v"),
        .json => try args.appendSlice(arena, &.{ "--output", "json" }),
    }
    var environ = std.process.Environ.Map.init(arena);
    try environ.put("USER", "tester");
    if (case.flags.missing_state) {
        try environ.put("XDG_STATE_HOME", "/nonexistent-zcube-golden-state");
    } else if (!case.flags.no_state) {
        try environ.put("XDG_STATE_HOME", state_root);
    }
    var stdout: Writer.Allocating = .init(arena);
    var stderr: Writer.Allocating = .init(arena);
    var failing: Writer = .{ .vtable = &.{ .drain = drain_fails }, .buffer = &.{} };
    var input = std.Io.Reader.fixed(case.flags.stdin_text);
    var fixture: Fixture = .{ .arena = arena, .script = case.script };
    const env: cli_env.Env = .{
        .io = testing.io,
        .arena = if (case.flags.no_memory) refusing_allocator else arena,
        .environ = &environ,
        .stdout = if (case.flags.stdout_full) &failing else &stdout.writer,
        .stderr = &stderr.writer,
        .stdin = &input,
        .stdin_is_terminal = case.flags.stdin_terminal,
        .stderr_is_terminal = false,
        .version = "0.0.0-test",
        .deterministic_ids = true,
        .fixed_now_ms = 0,
        .transport = if (case.script == .closed_port) null else .{
            .context = &fixture,
            .exchange = exchange,
        },
    };
    const exit = if (case.flags.silent_failure)
        cli.run_with(&env, args.items, silent_executor)
    else
        cli.run(&env, args.items);
    return .{ .exit = exit, .stdout = stdout.written(), .stderr = stderr.written() };
}

/// The state directory of a run: absolute, because the command line wants an absolute one.
fn state_root_of(arena: Allocator, tmp: *const testing.TmpDir) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(testing.io, arena);
    const format = "{s}/.zig-cache/tmp/{s}/state";
    return std.fmt.allocPrint(arena, format, .{ cwd, tmp.sub_path });
}

/// The output with the state directory (which differs per run) replaced by a name.
fn stable(arena: Allocator, text: []const u8, state_root: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, arena, text, state_root, "<state>");
}

const Golden = struct {
    text: []const u8,
    verbose: []const u8,
    json: []const u8,
};

/// Index of a code's goldens, built at compile time: a registered code without its three files
/// does not compile, which is the build check of DIAGNOSTICS.md ("a golden test for every code").
const goldens = blk: {
    var table: [codes.registry.len]Golden = undefined;
    for (codes.registry, 0..) |entry, index| {
        const name = @tagName(entry.code);
        table[index] = .{
            .text = @embedFile("testdata/cli/" ++ name ++ ".txt"),
            .verbose = @embedFile("testdata/cli/" ++ name ++ ".verbose.txt"),
            .json = @embedFile("testdata/cli/" ++ name ++ ".json.txt"),
        };
    }
    break :blk table;
};

fn golden_of(code: codes.Code, style: Style) []const u8 {
    const found = goldens[@backingInt(code)];
    return switch (style) {
        .text => found.text,
        .verbose => found.verbose,
        .json => found.json,
    };
}

/// Where to write goldens instead of comparing, if the environment says so.
fn update_directory() ?[]const u8 {
    return testing.environ.getPosix("ZCUBE_GOLDEN_UPDATE");
}

fn update_golden(directory: []const u8, code: codes.Code, style: Style, text: []const u8) !void {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const suffix = switch (style) {
        .text => "",
        .verbose => ".verbose",
        .json => ".json",
    };
    const format = "{s}/{s}{s}.txt";
    const name = try std.fmt.bufPrint(&path, format, .{ directory, @tagName(code), suffix });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = name, .data = text });
}

test "golden: every code in default, verbose and JSON output" {
    // Goal: the text of each diagnostic is part of the product. Method: run each case through the
    // real command line in each style and compare stderr byte for byte with the checked-in file;
    // the exit code is the blame's (the command's own for a warning), the code is in the output,
    // standard output is empty for a failure, and every JSON line parses.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state_root = try state_root_of(arena, &tmp);
    for (&cases) |*case| {
        for (std.enums.values(Style)) |style| {
            const output = try run_case(arena, case, style, state_root);
            const shown = try stable(arena, output.stderr, state_root);
            if (update_directory()) |directory| {
                try update_golden(directory, case.code, style, shown);
                continue;
            }
            try testing.expectEqualStrings(golden_of(case.code, style), shown);
            try check_case(case, style, output);
        }
    }
}

fn check_case(case: *const Case, style: Style, output: Output) !void {
    const full = codes.full_name(case.code);
    try testing.expect(std.mem.indexOf(u8, output.stderr, full) != null);
    const blame = codes.entry(case.code).blame;
    const expected: u8 = if (case.flags.warning) constants.exit_ok else codes.exit_code(blame);
    try testing.expectEqual(expected, output.exit);
    if (!case.flags.warning and !case.prints) {
        try testing.expectEqual(@as(usize, 0), output.stdout.len);
    }
    if (case.prints and style != .json) try testing.expect(output.stdout.len > 0);
    if (style != .json) return;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output.stderr, "\n"), '\n');
    while (lines.next()) |raw| {
        // With a terminal, the question of apply is the one thing on stderr that is not JSON; it
        // has no newline, so it shares a line with the first diagnostic.
        const line = std.mem.cutPrefix(u8, raw, "apply? [y/N] ") orelse raw;
        var scratch: [2 * constants.diag_output_bytes_max]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        _ = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), line, .{}) catch |err| {
            std.debug.print("{s}: not JSON: {s}\n", .{ full, line });
            return err;
        };
    }
}

test "every registered code has a case, and the panic is the one without a command line" {
    // Goal: the registry cannot gain a code without a golden test. B0001 is the panic handler's
    // (covered below); every other code has a case. The files themselves are checked at compile
    // time by `goldens` above.
    for (codes.registry) |entry| {
        if (entry.code == .B0001) continue;
        const covered = for (cases) |case| {
            if (case.code == entry.code) break true;
        } else false;
        try testing.expect(covered);
    }
    try testing.expectEqual(codes.registry.len - 1, cases.len);
}

/// True if `text` shows what DIAGNOSTICS.md forbids: a trace, a source location, an address or a
/// raw Zig error name. Narrower than Zigbox's detector on purpose: words such as "thread" are
/// ordinary English in a message ("could not start a thread").
fn shows_trace(text: []const u8) bool {
    const markers = [_][]const u8{
        ".zig:", "stack trace", "Stack trace", "panic:", "unreachable code",
    };
    for (markers) |marker| {
        if (std.mem.indexOf(u8, text, marker) != null) return true;
    }
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "error.")) |at| : (from = at + 1) {
        if (at + 6 < text.len and std.ascii.isAlphabetic(text[at + 6])) return true;
    }
    from = 0;
    while (std.mem.indexOfPos(u8, text, from, "0x")) |at| : (from = at + 1) {
        if (at + 2 < text.len and std.ascii.isHex(text[at + 2])) return true;
    }
    return false;
}

test "no raw errors: no output of any case shows a trace or a Zig error name" {
    // Goal: DIAGNOSTICS.md, "No stack traces for users". Method: every case in every style, both
    // streams, then the detector itself on text it must and must not flag.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state_root = try state_root_of(arena, &tmp);
    for (&cases) |*case| {
        for (std.enums.values(Style)) |style| {
            const output = try run_case(arena, case, style, state_root);
            try testing.expect(!shows_trace(try stable(arena, output.stderr, state_root)));
            try testing.expect(!shows_trace(output.stdout));
        }
    }
    try testing.expect(shows_trace("error.AccessDenied"));
    try testing.expect(shows_trace("at src/cli.zig:12:5"));
    try testing.expect(shows_trace("thread 4 panic: index out of bounds"));
    try testing.expect(shows_trace("address 0x7ffd1234"));
    try testing.expect(!shows_trace("the server could not start a thread for its work"));
    try testing.expect(!shows_trace("error[ZC-E0102]: can't reach zcube-server"));
}

test "golden: a panic, in default, verbose and JSON output" {
    // Goal: B0001 as the panic handler writes it. Method: the handler's text for a fixed message
    // in each mode. The default text hides the message; verbose and JSON show it; none shows a
    // trace.
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const message = "index out of bounds: index 5, len 3";
    const styles = [_]Style{ .text, .verbose, .json };
    const modes = [_]cli_report.Mode{ .text, .verbose, .json };
    for (styles, modes) |style, mode| {
        const text = cli_report.panic_text(message, mode, &buffer);
        if (update_directory()) |directory| {
            try update_golden(directory, .B0001, style, text);
            continue;
        }
        try testing.expectEqualStrings(golden_of(.B0001, style), text);
        try testing.expect(!shows_trace(text));
    }
    const hidden = golden_of(.B0001, .text);
    try testing.expect(std.mem.indexOf(u8, hidden, "index out of bounds") == null);
}

test "a bug the server reports gets a bundle on this machine, named in its saved line" {
    // Goal: "an automatic bundle on every bug diagnostic", also when the bug is the server's.
    // Method: a canned bug reply; the output names a bundle under the state directory, the exit
    // code is 70, and the file exists.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state_root = try state_root_of(arena, &tmp);
    const case = relayed(.B0001, server_bug);
    const output = try run_case(arena, &case, .text, state_root);
    try testing.expectEqual(constants.exit_internal, output.exit);
    const saved = try stable(arena, output.stderr, state_root);
    const name = "1970-01-01T00-00-00Z-last.tar.gz";
    try testing.expect(std.mem.indexOf(u8, saved, "<state>/zcube/bundles/" ++ name) != null);
    try tmp.dir.access(testing.io, "state/zcube/bundles/" ++ name, .{});
}
