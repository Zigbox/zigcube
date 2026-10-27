//! The server's listening socket. Shell code: sockets.
//!
//! The socket has `SO_REUSEADDR` and not `SO_REUSEPORT`. Without the first, a server that is
//! stopped and started again cannot listen on its port for a minute whenever it closed a
//! connection first (the server closes an idle connection, a reply that ends one, a connection
//! still open when it stops): the connection stays in `TIME_WAIT` and `bind` is refused with
//! `EADDRINUSE`. With the second, a second live server on the same port would start without
//! complaint and share it. The standard library's `listen` sets both when it is given
//! `reuse_address`, and gives no way to set the first alone before `bind`, so on Linux the
//! socket is made here. A port with an active listener is still refused (`SO_REUSEADDR` does not
//! allow that on Linux), which `server_test.zig` checks. Elsewhere the standard library's
//! strict listen is used, with the limit above.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const net = std.Io.net;
const linux = std.os.linux;
const Threaded = std.Io.Threaded;

pub const Error = error{ AddressInUse, AddressUnavailable, AccessDenied, Failed };

const backlog: u31 = 128;

pub fn listen(io: std.Io, where: net.IpAddress) Error!net.Server {
    if (builtin.os.tag != .linux) return listen_strict(io, where);
    var storage: Threaded.PosixAddress = undefined;
    const length = Threaded.addressToPosix(&where, &storage);
    const family: u32 = storage.any.family;
    const made = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(made) != .SUCCESS) return error.Failed;
    const handle: i32 = @intCast(made);
    errdefer _ = linux.close(handle);
    const on = std.mem.toBytes(@as(c_int, 1));
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &on) catch {
        return error.Failed;
    };
    switch (linux.errno(linux.bind(handle, &storage.any, length))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .ACCES, .PERM => return error.AccessDenied,
        else => return error.Failed,
    }
    if (linux.errno(linux.listen(handle, backlog)) != .SUCCESS) return error.AddressInUse;
    var bound_length: std.posix.socklen_t = @sizeOf(Threaded.PosixAddress);
    if (linux.errno(linux.getsockname(handle, &storage.any, &bound_length)) != .SUCCESS) {
        return error.Failed;
    }
    return .{
        .socket = .{ .handle = handle, .address = Threaded.addressFromPosix(&storage) },
        .options = {},
    };
}

fn listen_strict(io: std.Io, where: net.IpAddress) Error!net.Server {
    return where.listen(io, .{ .reuse_address = false }) catch |err| switch (err) {
        error.AddressInUse => error.AddressInUse,
        error.AddressUnavailable => error.AddressUnavailable,
        error.AccessDenied => error.AccessDenied,
        else => error.Failed,
    };
}
