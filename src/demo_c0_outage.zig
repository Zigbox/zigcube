//! Step 5 of HANDOFF's C0 demo: the store backend stops mid-demo. `zcube` must blame the backend
//! with a registered `ZC-` diagnostic and a fix (never a connection library's text), `zcube bundle
//! --last` must write a bundle, and when the backend is back the system recovers.
//!
//! **Postgres** is a server of its own, so it is stopped (`pg_ctl stop` for a local database,
//! `docker stop` for CI's service container) and started again with its data.
//!
//! **SQLite** is a library inside `zcube-server`; there is no backend process to stop, and the
//! file can't be made unreachable under a running server in any way that fails a read (a file that
//! is moved or deleted stays open; a permission change does not reach an open descriptor, and the
//! demo may run as root). What really happens to a SQLite store is that another process holds it:
//! a backup, a stray `sqlite3` session. So the demo takes the write lock from a second process
//! (`BEGIN EXCLUSIVE`, here in the demo's own process, which is not the server). In WAL mode
//! reads still work, so `zcube get` answers, and the demo asserts that; every write, here
//! `zcube apply`, fails with `ZC-E0208` after the server's busy wait. docs/demos/c0.md says so.

const std = @import("std");
const assert = std.debug.assert;
const sqlite = @import("sqlite_c");
const constants = @import("constants.zig");
const state = @import("demo_c0_state.zig");
const decisions = @import("demo_c0_decisions.zig");
const demo_host = @import("demo_host.zig");
const host_procs = @import("host_procs.zig");

const Demo = state.Demo;
const Host = state.Host;
const Json = state.Json;

pub fn run(demo: *Demo) !void {
    const host = demo.host;
    host.section("5. The store backend stops");
    const before = try host.procs().running_containers();
    const counts = (try state.service_counts(demo, "hello")).?;
    host.say("  hello before the outage: {d}/{d} running, generation {d}", .{
        counts.running, counts.desired, counts.generation,
    });
    try state.write_service(demo, "hello", state.hello_image, 3);
    switch (demo.backend) {
        .postgres => |control| try postgres_outage(demo, control),
        .sqlite => try sqlite_outage(demo),
    }
    try recovered(demo, before, counts);
}

// ---- Postgres ----

fn postgres_outage(demo: *Demo, control: state.PostgresControl) !void {
    const host = demo.host;
    try run_command(host, "the Postgres server is stopped", control.stop_command);
    demo.store_stopped = true;
    const refused = struct {
        fn check(_: *Demo, h: *Host) !bool {
            const cli = try h.zcube_quiet(&.{ "get", "service", "hello" });
            return cli.code != 0;
        }
    };
    try host.wait_for(demo, refused.check, "zcube to notice the store is gone", state.recover_ms);
    const get = try host.zcube(&.{ "get", "service", "hello" });
    try expect_store_error(host, get, "ZC-E0201", "can't reach the store backend");
    try host.check(
        state.contains(get.err, "cause  the Postgres server at"),
        "the cause names the backend, in words an operator reads",
        .{},
    );
    try host.check(
        state.contains(get.err, "fix    start Postgres"),
        "the diagnostic carries a fix",
        .{},
    );
    try host.check(
        !state.contains(get.err, "libpq") and !state.contains(get.err, "PQ"),
        "no connection-library text in the default output",
        .{},
    );
    const json = try host.zcube(&.{ "get", "service", "hello", "-o", "json" });
    try host.check(
        state.contains(json.err, "\"code\":\"ZC-E0201\"") and
            state.contains(json.err, "\"blame\":\"external\""),
        "--output json: code ZC-E0201, blame external",
        .{},
    );
    try bundle_last(demo, "ZC-E0201", .store_down);
    const apply = try host.zcube(&.{ "apply", "--yes", "hello.zon" });
    try expect_store_error(host, apply, "ZC-E0201", "can't reach the store backend");
}

// ---- SQLite ----

/// A second connection that holds SQLite's write lock until `release`.
const SqliteLock = struct {
    db: ?*sqlite.sqlite3,

    fn acquire(path: [:0]const u8) !SqliteLock {
        var handle: ?*sqlite.sqlite3 = null;
        const flags = sqlite.SQLITE_OPEN_READWRITE;
        if (sqlite.sqlite3_open_v2(path.ptr, &handle, flags, null) != sqlite.SQLITE_OK) {
            if (handle) |open| _ = sqlite.sqlite3_close(open);
            return error.DemoFailed;
        }
        var lock: SqliteLock = .{ .db = handle };
        errdefer lock.release();
        // The server may be mid-write: wait for it, within a bound.
        _ = sqlite.sqlite3_busy_timeout(handle.?, @intCast(state.converge_ms));
        const rc = sqlite.sqlite3_exec(handle.?, "BEGIN EXCLUSIVE", null, null, null);
        if (rc != sqlite.SQLITE_OK) return error.DemoFailed;
        return lock;
    }

    /// Idempotent: the demo releases the lock once, and cleanup releases it again on a failure.
    fn release(lock: *SqliteLock) void {
        const db = lock.db orelse return;
        _ = sqlite.sqlite3_exec(db, "ROLLBACK", null, null, null);
        _ = sqlite.sqlite3_close(db);
        lock.db = null;
    }
};

fn sqlite_outage(demo: *Demo) !void {
    const host = demo.host;
    const path = try std.fmt.allocPrintSentinel(host.arena(), "{s}/store.db", .{host.work}, 0);
    host.say("  (a second process takes the write lock on store.db: BEGIN EXCLUSIVE)", .{});
    var lock = SqliteLock.acquire(path) catch {
        return host.fail("could not take SQLite's write lock on {s}", .{path});
    };
    defer lock.release();
    const get = try host.zcube(&.{ "get", "service", "hello" });
    try host.check(
        get.code == 0 and std.mem.eql(u8, state.ready_of(get.out, "hello") orelse "", "2/2"),
        "reads still work in WAL mode: zcube get service hello answers 2/2",
        .{},
    );
    const apply = try host.zcube(&.{ "apply", "--yes", "hello.zon" });
    try expect_store_error(host, apply, "ZC-E0208", "the store database is busy");
    try host.check(
        state.contains(apply.err, "cause  another connection held the write lock for over"),
        "the cause says who holds the store",
        .{},
    );
    try host.check(
        state.contains(apply.err, "fix    stop whatever else uses the store file"),
        "the diagnostic carries a fix",
        .{},
    );
    try bundle_last(demo, "ZC-E0208", .store_busy);
    host.say("  (the second process lets go of the lock)", .{});
    lock.release();
}

// ---- What both do ----

/// A refused command: the exit code of its blame, and the registered code and summary.
fn expect_store_error(
    host: *Host,
    cli: demo_host.Cli,
    code: []const u8,
    summary: []const u8,
) !void {
    const first = try std.fmt.allocPrint(host.arena(), "error[{s}]: {s}", .{ code, summary });
    const want_exit: u8 = if (std.mem.eql(u8, code, "ZC-E0201"))
        constants.exit_external
    else
        constants.exit_environment;
    try host.check(cli.code == want_exit, "exit code {d} (the blame of {s})", .{ want_exit, code });
    try host.check(
        std.mem.eql(u8, state.first_line(cli.err), first),
        "the diagnostic is {s}: {s}",
        .{ code, summary },
    );
    try host.check(state.contains(cli.err, "\n  fix "), "it has a fix", .{});
    try state.expect_no_trace(host, cli);
}

/// What the store was like when the bundle was made: down (Postgres: the server answers
/// `GET /v1/status` with the diagnostic and refuses everything that reads the store) or busy
/// (SQLite: the server reads, and its `status.json` and keys are in the bundle).
const StoreState = enum { store_down, store_busy };

/// `zcube bundle --last` writes a bundle whose MANIFEST.txt is the one it prints, and whose
/// diagnostic is the failure that was asked about.
fn bundle_last(demo: *Demo, code: []const u8, store_state: StoreState) !void {
    const host = demo.host;
    const cli = try host.zcube(&.{ "bundle", "--last" });
    try host.check(cli.code == 0, "zcube bundle --last wrote a bundle", .{});
    const marker = "bundle saved: ";
    const start = std.mem.find(u8, cli.out, marker) orelse {
        return host.fail("zcube bundle --last printed no '{s}' line", .{marker});
    };
    const rest = cli.out[start + marker.len ..];
    const path = state.first_line(rest);
    try host.check(std.mem.endsWith(u8, path, ".tar.gz"), "the bundle is one .tar.gz", .{});
    const manifest = try read_member(host, path, "*/MANIFEST.txt");
    try host.check(
        state.contains(cli.out, std.mem.trimEnd(u8, manifest, "\n")),
        "the MANIFEST.txt read back from the bundle is the one zcube printed",
        .{},
    );
    const listed = [_][]const u8{ "command.txt", "diagnostic.json", "version.txt", "status.json" };
    for (listed) |name| {
        try host.check(state.contains(manifest, name), "MANIFEST.txt lists {s}", .{name});
    }
    try host.check(
        state.contains(manifest, "redaction: on"),
        "MANIFEST.txt says redaction is on",
        .{},
    );
    const diagnostic = try read_member(host, path, "*/diagnostic.json");
    try host.check(state.contains(diagnostic, code), "diagnostic.json holds {s}", .{code});
    const status = try read_member(host, path, "*/status.json");
    switch (store_state) {
        .store_down => {
            try host.check(
                state.contains(status, "\"ok\":false") and state.contains(status, code),
                "status.json records that the store was down, with {s}",
                .{code},
            );
            try host.check(
                state.contains(manifest, ".unavailable.txt"),
                "MANIFEST.txt says which evidence could not be had (.unavailable.txt)",
                .{},
            );
        },
        .store_busy => try host.check(
            state.contains(status, "\"ok\":true") and
                state.contains(manifest, "keys/services.json"),
            "status.json and the store keys were collected: the store still answers reads",
            .{},
        ),
    }
}

/// One file of a bundle, by `tar` (an archive of the user's own tool, read as they would).
fn read_member(host: *Host, bundle: []const u8, pattern: []const u8) ![]const u8 {
    const result = std.process.run(host.arena(), host.io, .{
        .argv = &.{ "tar", "-xzOf", bundle, "--wildcards", pattern },
        .stdout_limit = .limited(demo_host.output_bytes_max),
        .stderr_limit = .limited(4096),
    }) catch |err| return host.fail("could not run tar: {s}", .{@errorName(err)});
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    return host.fail("tar could not read {s} from the bundle: {s}", .{ pattern, result.stderr });
}

/// Runs a shell command that stops or starts the database server, with its output in a file
/// (a daemon that inherits a pipe would keep it open for as long as it runs).
fn run_command(host: *Host, comptime what: []const u8, command: []const u8) !void {
    const log = try host.path_in_work("store-command.log");
    const format = "{s} >{s} 2>&1 </dev/null";
    const wrapped = try std.fmt.allocPrint(host.arena(), format, .{ command, log });
    host.say("$ {s}", .{command});
    const result = std.process.run(host.arena(), host.io, .{
        .argv = &.{ "sh", "-c", wrapped },
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(state.store_command_ms),
            .clock = .awake,
        } },
    }) catch |err| return host.fail("'{s}' did not finish: {s}", .{ command, @errorName(err) });
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        const cwd = std.Io.Dir.cwd();
        const text = cwd.readFileAlloc(host.io, log, host.arena(), .limited(4096)) catch "";
        host.say("{s}", .{text});
    }
    try host.check(ok, what, .{});
}

pub fn start_postgres(demo: *Demo, control: state.PostgresControl) !void {
    try run_command(demo.host, "the Postgres server is started again", control.start_command);
    demo.store_stopped = false;
}

/// The backend is back: `zcube` answers, nothing that ran stopped, the apply that was refused
/// changed nothing, and the controllers work again (the same apply now goes through).
fn recovered(demo: *Demo, before: []const host_procs.Pids, counts: state.Counts) !void {
    const host = demo.host;
    switch (demo.backend) {
        .postgres => |control| try start_postgres(demo, control),
        .sqlite => {},
    }
    const answering = struct {
        fn check(d: *Demo, _: *Host) !bool {
            return (try state.service_counts(d, "hello")) != null;
        }
    };
    try host.wait_for(demo, answering.check, "zcube get to answer again", state.recover_ms);
    const get = try host.zcube(&.{ "get", "service", "hello" });
    try host.check(
        std.mem.eql(u8, state.ready_of(get.out, "hello") orelse "", "2/2"),
        "after the outage hello is still 2/2",
        .{},
    );
    const after = (try state.service_counts(demo, "hello")).?;
    try host.check(
        after.generation == counts.generation and after.desired == counts.desired,
        "the refused apply changed nothing (generation {d}, {d} replicas)",
        .{ after.generation, after.desired },
    );
    try host.check(
        state.same_containers(before, try host.procs().running_containers()),
        "the workloads kept running through the outage: the same processes",
        .{},
    );
    try decisions.expect_new(demo, "outage", &.{});
    try apply_again(demo);
}

fn apply_again(demo: *Demo) !void {
    const host = demo.host;
    const apply = try host.zcube(&.{ "apply", "--yes", "hello.zon" });
    try host.check(apply.code == 0, "the same apply now goes through", .{});
    try host.check(
        state.contains(apply.out, "applied service hello: replicas 2 → 3"),
        "applied service hello: replicas 2 → 3",
        .{},
    );
    const three = struct {
        fn check(d: *Demo, _: *Host) !bool {
            const counts = (try state.service_counts(d, "hello")) orelse return false;
            return counts.running == 3;
        }
    };
    const what = "the controllers to start the third replica";
    try host.wait_for(demo, three.check, what, state.converge_ms);
    try state.expect_processes(demo, "after recovery", 3);
    try decisions.expect_new(demo, "after recovery", &.{
        .{ .actor = "api", .action = "apply", .count = 1 },
        .{ .actor = "replica-controller", .action = "scale_up", .count = 1 },
        .{ .actor = "replica-controller", .action = "create_replica", .count = 1 },
        .{ .actor = "scheduler", .action = "place_replica", .count = 1 },
    });
}
