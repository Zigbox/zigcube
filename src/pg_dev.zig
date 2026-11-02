//! `pg_dev`: brings a throwaway Postgres up and down for the store conformance suite and demo-c0.
//! `zig build pg-up` starts one, `zig build pg-down` stops it and deletes its files. It is build
//! tooling, so it is Zig (docs/STYLE.md), and it needs no database to exist before it runs.
//!
//! The server listens on 127.0.0.1 only, with trust authentication and `fsync` off: it holds
//! nothing worth keeping. `initdb` and `postgres` refuse to run as root, so as root the tool runs
//! them as the `postgres` user (`runuser`), in a directory that user creates.
//!
//! Settings, all optional: `ZCUBE_PG_DIR` (default `/tmp/zcube-pg`), `ZCUBE_PG_PORT` (default
//! `55432`) and `ZCUBE_PG_BIN`, the directory of the Postgres programs when they are not on PATH
//! (the session-start hook puts them there).
//!
//! ## The pair (slice 10d)
//!
//! `pair-up sync|async` makes a primary and a streaming standby for the failover runs of
//! `test-store-faults` (`src/store_failover.zig`), in `ZCUBE_PG_PAIR_DIR` (data in `primary/` and
//! `standby/`), the primary on `ZCUBE_PG_PAIR_PORT` and the standby on the next port. The
//! defaults are the worktree's own: `/tmp/zcube-pg-pair-<hash>` and an even port from 21000 to
//! 22998, both from a hash of the working directory, so that two worktrees running the failover
//! runs at once never touch each other's pair. A pair left by an earlier run of this worktree is
//! removed first: each failover run kills its primary, so a pair is never reused. The standby is
//! made with `pg_basebackup -R` and reports itself as `zcube_standby`. `sync` is the supported
//! setup (docs/briefs/c1.md, "Supported Postgres setup"): the primary runs with `synchronous_commit
//! = remote_apply` and the standby in `synchronous_standby_names`. `async` has neither, which is
//! the setup the failover run shows is refused after a loss. `pair-crash` stops the primary with
//! `pg_ctl -m immediate` (no shutdown checkpoint: a crash), `pair-promote` promotes the standby and
//! waits until it accepts writes, `pair-down` stops both and deletes the directory. Both nodes run
//! with `fsync` off, like the single server: that is sound for the crash `pair-crash` makes (a
//! process crash leaves written WAL in the page cache, where a restart finds it), and would not be
//! for a host crash, which the runs do not make. It prints nothing on success but `pair-up`'s two
//! connection lines.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const exit_environment = constants.exit_environment;

const Config = struct {
    dir: []const u8,
    port: []const u8,
    bin: ?[]const u8,
    as_postgres: bool,
    pair_dir: []const u8,
    /// The primary's port; the standby's is the next one.
    pair_port: u16,

    /// The connection settings the suite uses, as `libpq` reads them.
    fn conninfo(config: Config, buffer: []u8) []const u8 {
        const format = "host=127.0.0.1 port={s} user=zcube dbname=postgres";
        return std.fmt.bufPrint(buffer, format, .{config.port}) catch unreachable; // Short.
    }
};

/// The pair's default ports and directory are the worktree's own (a hash of the working
/// directory picks a slot), so that runs in two worktrees never share, or delete, one pair.
/// Below the kernel's ephemeral range (as `demo_host.free_port`): after `pair-crash` the proxy
/// keeps connecting to the dead primary's port, and a connection from an ephemeral port to a
/// port in that range with no listener can connect to itself and hold the port.
const pair_port_base: u16 = 21_000;
const pair_port_slots = 1000;
const pair_dir_prefix = "/tmp/zcube-pg-pair-";

const PairDefaults = struct { dir: []const u8, port: u16 };

fn pair_defaults(init: std.process.Init) !PairDefaults {
    const arena = init.arena.allocator();
    const cwd = try std.process.currentPathAlloc(init.io, arena);
    const hash = std.hash.Wyhash.hash(0, cwd);
    const slot: u16 = @intCast(hash % pair_port_slots);
    return .{
        .dir = try std.fmt.allocPrint(arena, "{s}{x:0>8}", .{ pair_dir_prefix, hash >> 32 }),
        .port = pair_port_base + slot * 2,
    };
}

comptime {
    assert(pair_port_base + pair_port_slots * 2 < std.math.maxInt(u16));
}
/// The name the standby reports to the primary, and the one `synchronous_standby_names` lists.
pub const standby_name = "zcube_standby";

pub const Mode = enum { sync, async };

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return constants.exit_user;
    if (args.len < 2) return usage(init.io);
    if (args.len > 3) return usage(init.io);
    const defaults = pair_defaults(init) catch {
        say(init.io, "pg_dev: cannot read the working directory\n");
        return constants.exit_environment;
    };
    const port_text = init.environ_map.get("ZCUBE_PG_PAIR_PORT");
    const pair_port = if (port_text) |text| std.fmt.parseInt(u16, text, 10) catch {
        say(init.io, "ZCUBE_PG_PAIR_PORT is not a port number\n");
        return constants.exit_user;
    } else defaults.port;
    if (pair_port == 0) return usage(init.io);
    if (pair_port == std.math.maxInt(u16)) return usage(init.io);
    const config: Config = .{
        .dir = init.environ_map.get("ZCUBE_PG_DIR") orelse "/tmp/zcube-pg",
        .port = init.environ_map.get("ZCUBE_PG_PORT") orelse "55432",
        .bin = init.environ_map.get("ZCUBE_PG_BIN"),
        .as_postgres = std.os.linux.geteuid() == 0,
        .pair_dir = init.environ_map.get("ZCUBE_PG_PAIR_DIR") orelse defaults.dir,
        .pair_port = pair_port,
    };
    const command = args[1];
    if (args.len == 3) {
        if (!std.mem.eql(u8, command, "pair-up")) return usage(init.io);
        const mode = std.meta.stringToEnum(Mode, args[2]) orelse return usage(init.io);
        return pair_up(init, config, mode);
    }
    if (std.mem.eql(u8, command, "up")) return up(init, config);
    if (std.mem.eql(u8, command, "down")) return down(init, config);
    if (std.mem.eql(u8, command, "stop")) return stop(init, config);
    if (std.mem.eql(u8, command, "pair-crash")) return pair_crash(init, config);
    if (std.mem.eql(u8, command, "pair-promote")) return pair_promote(init, config);
    if (std.mem.eql(u8, command, "pair-down")) return pair_down(init, config);
    return usage(init.io);
}

fn usage(io: std.Io) u8 {
    say(io, "usage: pg_dev up | stop | down | pair-up sync|async | pair-crash | pair-promote" ++
        " | pair-down\n");
    return constants.exit_user;
}

fn say(io: std.Io, text: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to report it.
}

/// Runs `argv` (as the `postgres` user when we are root). True if it exited 0; its output is
/// shown only when it failed.
fn run(init: std.process.Init, config: Config, argv: []const []const u8) bool {
    return run_showing(init, config, argv, true);
}

/// `run` for a question (a test whose "no" is an answer, not a failure): shows nothing.
fn run_quiet(init: std.process.Init, config: Config, argv: []const []const u8) bool {
    return run_showing(init, config, argv, false);
}

fn run_showing(
    init: std.process.Init,
    config: Config,
    argv: []const []const u8,
    show_failure: bool,
) bool {
    assert(argv.len > 0);
    assert(argv.len <= 12);
    var full: [16][]const u8 = undefined;
    var count: usize = 0;
    if (config.as_postgres) {
        for ([_][]const u8{ "runuser", "-u", "postgres", "--" }) |word| {
            full[count] = word;
            count += 1;
        }
    }
    for (argv) |word| {
        full[count] = word;
        count += 1;
    }
    const result = std.process.run(init.gpa, init.io, .{ .argv = full[0..count] }) catch {
        say(init.io, "could not start a program; is Postgres installed?\n");
        return false;
    };
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok and show_failure) say(init.io, result.stderr);
    return ok;
}

fn program(arena: std.mem.Allocator, config: Config, name: []const u8) ![]const u8 {
    const bin = config.bin orelse return name;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ bin, name });
}

fn up(init: std.process.Init, config: Config) u8 {
    const arena = init.arena.allocator();
    const initdb = program(arena, config, "initdb") catch return exit_environment;
    const pg_ctl = program(arena, config, "pg_ctl") catch return exit_environment;
    const data = std.fmt.allocPrint(arena, "{s}/data", .{config.dir}) catch return exit_environment;
    const log = std.fmt.allocPrint(arena, "{s}/log", .{config.dir}) catch return exit_environment;
    const options = std.fmt.allocPrint(
        arena,
        "-p {s} -k {s} -c listen_addresses=127.0.0.1 -c fsync=off -c max_connections=200",
        .{ config.port, config.dir },
    ) catch return exit_environment;
    if (!run(init, config, &.{ "mkdir", "-p", config.dir })) return constants.exit_environment;
    // A cluster that exists but is stopped is started, not made again (`initdb` refuses a
    // directory that is not empty, and `pg_ctl status` says "no" for a stopped one).
    const marker = std.fmt.allocPrint(arena, "{s}/PG_VERSION", .{data}) catch
        return exit_environment;
    const present = run(init, config, &.{ "test", "-f", marker });
    if (!present) {
        const made = run(init, config, &.{ initdb, "-D", data, "-A", "trust", "-U", "zcube" });
        if (!made) return constants.exit_environment;
    }
    const start = [_][]const u8{ pg_ctl, "-D", data, "-o", options, "-l", log, "-w", "start" };
    const started = run(init, config, &start);
    if (!started and !run(init, config, &.{ pg_ctl, "-D", data, "status" })) {
        return constants.exit_environment;
    }
    var buffer: [128]u8 = undefined;
    const format = "ZCUBE_TEST_POSTGRES={s}\n";
    const line = std.fmt.allocPrint(arena, format, .{config.conninfo(&buffer)}) catch
        return exit_environment;
    std.Io.File.stdout().writeStreamingAll(init.io, line) catch return exit_environment;
    return constants.exit_ok;
}

/// Stops the server and keeps its data, for a test that stops the database and starts it again
/// with `up` (which starts a cluster that exists). Fails if the server was not running.
fn stop(init: std.process.Init, config: Config) u8 {
    const arena = init.arena.allocator();
    const pg_ctl = program(arena, config, "pg_ctl") catch return exit_environment;
    const data = std.fmt.allocPrint(arena, "{s}/data", .{config.dir}) catch return exit_environment;
    if (!run(init, config, &.{ pg_ctl, "-D", data, "-m", "fast", "-w", "stop" })) {
        return constants.exit_environment;
    }
    return constants.exit_ok;
}

fn down(init: std.process.Init, config: Config) u8 {
    const arena = init.arena.allocator();
    const pg_ctl = program(arena, config, "pg_ctl") catch return exit_environment;
    const data = std.fmt.allocPrint(arena, "{s}/data", .{config.dir}) catch return exit_environment;
    // A server that is not running is the state we want, so a failed stop is not an error.
    _ = run(init, config, &.{ pg_ctl, "-D", data, "-m", "fast", "-w", "stop" });
    if (!run(init, config, &.{ "rm", "-rf", config.dir })) return constants.exit_environment;
    return constants.exit_ok;
}

// ---- The pair -----------------------------------------------------------------------------------

const Node = enum { primary, standby };

fn node_data(arena: std.mem.Allocator, config: Config, node: Node) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ config.pair_dir, @tagName(node) });
}

fn node_port(config: Config, node: Node) u16 {
    return switch (node) {
        .primary => config.pair_port,
        .standby => config.pair_port + 1,
    };
}

/// Starts one node of the pair with `extra` settings after the common ones.
fn pair_start(init: std.process.Init, config: Config, node: Node, extra: []const u8) !void {
    const arena = init.arena.allocator();
    const pg_ctl = try program(arena, config, "pg_ctl");
    const data = try node_data(arena, config, node);
    const log = try std.fmt.allocPrint(arena, "{s}/{s}.log", .{ config.pair_dir, @tagName(node) });
    const options = try std.fmt.allocPrint(
        arena,
        "-p {d} -k {s} -c listen_addresses=127.0.0.1 -c fsync=off -c max_connections=100 {s}",
        .{ node_port(config, node), config.pair_dir, extra },
    );
    const start = [_][]const u8{ pg_ctl, "-D", data, "-o", options, "-l", log, "-w", "start" };
    if (!run(init, config, &start)) return error.StartFailed;
}

fn pair_up(init: std.process.Init, config: Config, mode: Mode) u8 {
    if (pair_down(init, config) != constants.exit_ok) return constants.exit_environment;
    pair_make(init, config, mode) catch |err| {
        var buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "pair-up failed: {s}\n", .{@errorName(err)}) catch
            "pair-up failed\n";
        say(init.io, text);
        _ = pair_down(init, config);
        return constants.exit_environment;
    };
    const arena = init.arena.allocator();
    const format = "ZCUBE_PG_PRIMARY=host=127.0.0.1 port={d} user=zcube dbname=postgres\n" ++
        "ZCUBE_PG_STANDBY=host=127.0.0.1 port={d} user=zcube dbname=postgres\n";
    const ports = .{ node_port(config, .primary), node_port(config, .standby) };
    const lines = std.fmt.allocPrint(arena, format, ports) catch return exit_environment;
    std.Io.File.stdout().writeStreamingAll(init.io, lines) catch return exit_environment;
    return constants.exit_ok;
}

/// initdb, the primary, a base backup, the standby. `wal_retrieve_retry_interval` is short so that
/// a standby whose replication connection was moved or cut streams again within a poll or two.
fn pair_make(init: std.process.Init, config: Config, mode: Mode) !void {
    const arena = init.arena.allocator();
    const initdb = try program(arena, config, "initdb");
    const basebackup = try program(arena, config, "pg_basebackup");
    const primary = try node_data(arena, config, .primary);
    const standby = try node_data(arena, config, .standby);
    if (!run(init, config, &.{ "mkdir", "-p", config.pair_dir })) return error.MkdirFailed;
    if (!run(init, config, &.{ initdb, "-D", primary, "-A", "trust", "-U", "zcube" })) {
        return error.InitdbFailed;
    }
    const sync_settings = "-c synchronous_commit=remote_apply -c synchronous_standby_names=" ++
        standby_name;
    try pair_start(init, config, .primary, if (mode == .sync) sync_settings else "");
    const source = try std.fmt.allocPrint(
        arena,
        "host=127.0.0.1 port={d} user=zcube application_name={s}",
        .{ node_port(config, .primary), standby_name },
    );
    const backup = [_][]const u8{ basebackup, "-D", standby, "-d", source, "-R", "-X", "stream" };
    if (!run(init, config, &backup)) return error.BasebackupFailed;
    try pair_start(init, config, .standby, "-c wal_retrieve_retry_interval=100ms");
}

fn pair_crash(init: std.process.Init, config: Config) u8 {
    const arena = init.arena.allocator();
    const pg_ctl = program(arena, config, "pg_ctl") catch return exit_environment;
    const data = node_data(arena, config, .primary) catch return exit_environment;
    if (!run(init, config, &.{ pg_ctl, "-D", data, "-m", "immediate", "-w", "stop" })) {
        return constants.exit_environment;
    }
    return constants.exit_ok;
}

fn pair_promote(init: std.process.Init, config: Config) u8 {
    const arena = init.arena.allocator();
    const pg_ctl = program(arena, config, "pg_ctl") catch return exit_environment;
    const data = node_data(arena, config, .standby) catch return exit_environment;
    if (!run(init, config, &.{ pg_ctl, "-D", data, "-w", "promote" })) {
        return constants.exit_environment;
    }
    return constants.exit_ok;
}

/// Stops whatever runs (immediately: the pair holds nothing worth a checkpoint) and deletes the
/// directory. A node that is not running is the state we want, so a failed stop is not an error.
fn pair_down(init: std.process.Init, config: Config) u8 {
    const arena = init.arena.allocator();
    const pg_ctl = program(arena, config, "pg_ctl") catch return exit_environment;
    for ([_]Node{ .standby, .primary }) |node| {
        const data = node_data(arena, config, node) catch return exit_environment;
        const marker = std.fmt.allocPrint(arena, "{s}/PG_VERSION", .{data}) catch
            return exit_environment;
        if (!run_quiet(init, config, &.{ "test", "-f", marker })) continue;
        _ = run_quiet(init, config, &.{ pg_ctl, "-D", data, "-m", "immediate", "-w", "stop" });
    }
    if (!run(init, config, &.{ "rm", "-rf", config.pair_dir })) return constants.exit_environment;
    return constants.exit_ok;
}
