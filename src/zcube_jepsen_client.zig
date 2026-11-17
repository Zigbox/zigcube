//! `zcube-jepsen-client`: the process around `jepsen_client.zig`. It appends the invocation line
//! to the history before the request leaves, and the completion after, each with one `write(2)`
//! on a file opened with `O_APPEND`, so lines from concurrent clients never interleave. The
//! completion is also printed. A test-only tool (docs/jepsen.md); `zig build jepsen-client`.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const cli_env = @import("cli_env.zig");
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const history = @import("jepsen_history.zig");
const jepsen = @import("jepsen_client.zig");

const exit_usage: u8 = 64;
/// The history file cannot be opened or written: no line can say what happened.
const exit_history: u8 = 74;

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch return exit_usage;
    var err_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &err_buffer);
    defer stderr.interface.flush() catch {}; // Nowhere else to report it.
    if (argv.len == 2 and std.mem.eql(u8, argv[1], "--help")) {
        stderr.interface.writeAll(jepsen.usage) catch {};
        return 0;
    }
    var problem: []const u8 = "";
    const args = jepsen.parse(argv[1..], &problem) catch {
        const usage = jepsen.usage;
        stderr.interface.print("zcube-jepsen-client: {s}\n{s}", .{ problem, usage }) catch {};
        return exit_usage;
    };
    const path = arena.dupeSentinel(u8, args.history, 0) catch return exit_history;
    const opened = linux.open(path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o644);
    if (linux.errno(opened) != .SUCCESS) {
        stderr.interface.print("zcube-jepsen-client: cannot open {s}\n", .{args.history}) catch {};
        return exit_history;
    }
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);

    var out_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    const env: cli_env.Env = .{
        .io = init.io,
        .arena = arena,
        .environ = init.environ_map,
        .stdout = &stdout.interface,
        .stderr = &stderr.interface,
        .stdin = null,
        .stdin_is_terminal = false,
        .stderr_is_terminal = false,
        .version = "jepsen-client",
    };
    var report: cli_report.Report = undefined;
    report.reset();
    var client: cli_http.Client = undefined;
    client.init(&env, args.server, args.tls, &report) catch {
        const why = report.diag.last_cause() orelse "bad --server or TLS files";
        stderr.interface.print("zcube-jepsen-client: {s}\n", .{why}) catch {};
        return exit_usage;
    };
    const invoke = jepsen.invocation(args, now_ns(init.io));
    if (!append(arena, fd, invoke)) return exit_history;
    var done = jepsen.perform(&env, &client, args, invoke);
    done.time_ns = now_ns(init.io);
    if (!append(arena, fd, done)) return exit_history;
    const text = encode(arena, done) orelse return exit_history;
    std.Io.File.stdout().writeStreamingAll(init.io, text) catch {}; // The file has it.
    return jepsen.exit_code(done);
}

fn now_ns(io: std.Io) u64 {
    const ns = std.Io.Clock.boot.now(io).toNanoseconds();
    assert(ns > 0);
    return @intCast(ns);
}

fn encode(arena: std.mem.Allocator, line: history.Line) ?[]const u8 {
    var text: std.Io.Writer.Allocating = .init(arena);
    history.write(line, &text.writer) catch return null;
    const written = text.written();
    if (written.len > history.line_bytes_max) return null;
    return written;
}

/// One `write(2)`: a short write on a regular file means the disk is full, and the line is
/// then cut, which the harness reads as a broken history.
fn append(arena: std.mem.Allocator, fd: linux.fd_t, line: history.Line) bool {
    const text = encode(arena, line) orelse return false;
    const wrote = linux.write(fd, text.ptr, text.len);
    if (linux.errno(wrote) != .SUCCESS) return false;
    return wrote == text.len;
}
