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

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const Config = struct {
    dir: []const u8,
    port: []const u8,
    bin: ?[]const u8,
    as_postgres: bool,

    /// The connection settings the suite uses, as `libpq` reads them.
    fn conninfo(config: Config, buffer: []u8) []const u8 {
        const format = "host=127.0.0.1 port={s} user=zcube dbname=postgres";
        return std.fmt.bufPrint(buffer, format, .{config.port}) catch unreachable; // Short.
    }
};

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return constants.exit_user;
    if (args.len != 2) return usage(init.io);
    const config: Config = .{
        .dir = init.environ_map.get("ZCUBE_PG_DIR") orelse "/tmp/zcube-pg",
        .port = init.environ_map.get("ZCUBE_PG_PORT") orelse "55432",
        .bin = init.environ_map.get("ZCUBE_PG_BIN"),
        .as_postgres = std.os.linux.geteuid() == 0,
    };
    const command = args[1];
    if (std.mem.eql(u8, command, "up")) return up(init, config);
    if (std.mem.eql(u8, command, "down")) return down(init, config);
    if (std.mem.eql(u8, command, "stop")) return stop(init, config);
    return usage(init.io);
}

fn usage(io: std.Io) u8 {
    say(io, "usage: pg_dev up | stop | down\n");
    return constants.exit_user;
}

fn say(io: std.Io, text: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to report it.
}

/// Runs `argv` (as the `postgres` user when we are root). True if it exited 0; its output is
/// shown only when it failed.
fn run(init: std.process.Init, config: Config, argv: []const []const u8) bool {
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
    if (!ok) say(init.io, result.stderr);
    return ok;
}

fn program(arena: std.mem.Allocator, config: Config, name: []const u8) ![]const u8 {
    const bin = config.bin orelse return name;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ bin, name });
}

fn up(init: std.process.Init, config: Config) u8 {
    const arena = init.arena.allocator();
    const initdb = program(arena, config, "initdb") catch return constants.exit_environment;
    const pg_ctl = program(arena, config, "pg_ctl") catch return constants.exit_environment;
    const data = std.fmt.allocPrint(arena, "{s}/data", .{config.dir}) catch return 2;
    const log = std.fmt.allocPrint(arena, "{s}/log", .{config.dir}) catch return 2;
    const options = std.fmt.allocPrint(
        arena,
        "-p {s} -k {s} -c listen_addresses=127.0.0.1 -c fsync=off -c max_connections=200",
        .{ config.port, config.dir },
    ) catch return constants.exit_environment;
    if (!run(init, config, &.{ "mkdir", "-p", config.dir })) return constants.exit_environment;
    // A cluster that exists but is stopped is started, not made again (`initdb` refuses a
    // directory that is not empty, and `pg_ctl status` says "no" for a stopped one).
    const marker = std.fmt.allocPrint(arena, "{s}/PG_VERSION", .{data}) catch return 2;
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
    const line = std.fmt.allocPrint(arena, format, .{config.conninfo(&buffer)}) catch return 2;
    std.Io.File.stdout().writeStreamingAll(init.io, line) catch return 2;
    return constants.exit_ok;
}

/// Stops the server and keeps its data, for a test that stops the database and starts it again
/// with `up` (which starts a cluster that exists). Fails if the server was not running.
fn stop(init: std.process.Init, config: Config) u8 {
    const arena = init.arena.allocator();
    const pg_ctl = program(arena, config, "pg_ctl") catch return constants.exit_environment;
    const data = std.fmt.allocPrint(arena, "{s}/data", .{config.dir}) catch return 2;
    if (!run(init, config, &.{ pg_ctl, "-D", data, "-m", "fast", "-w", "stop" })) {
        return constants.exit_environment;
    }
    return constants.exit_ok;
}

fn down(init: std.process.Init, config: Config) u8 {
    const arena = init.arena.allocator();
    const pg_ctl = program(arena, config, "pg_ctl") catch return constants.exit_environment;
    const data = std.fmt.allocPrint(arena, "{s}/data", .{config.dir}) catch return 2;
    // A server that is not running is the state we want, so a failed stop is not an error.
    _ = run(init, config, &.{ pg_ctl, "-D", data, "-m", "fast", "-w", "stop" });
    if (!run(init, config, &.{ "rm", "-rf", config.dir })) return constants.exit_environment;
    return constants.exit_ok;
}
