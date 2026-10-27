//! The browser module of the console (`zig build console-wasm`): the doorway to `console_sim.zig`,
//! which is the real core over a memory store and the simulated runtime. The page loads it for
//! `?sim=c0`. This file is exports and one import, nothing else.
//!
//! **Exports** are flat (integers, pointers, `f64`; docs/wasm.md row 12):
//!
//! - `zc_init() u32`: creates the world. 0 on success.
//! - `zc_request_ptr() [*]u8`, `zc_request(len) u32`: the host writes a request frame
//!   (`console_sim.parse_frame`) at the pointer and calls with its length; the answer is the HTTP
//!   status. Then `zc_response_ptr/len` (the JSON body), `zc_response_id_ptr/len` (the request id)
//!   and `zc_response_hold_ms` (how long a watch may be held) describe it. They stay valid until
//!   the next call that touches the world.
//! - `zc_advance(ms)`: moves virtual time. `zc_now_ms() f64`, `zc_revision() f64` (-1: store down).
//! - `zc_control(op, arg) i32`: scenario and fault controls (`console_sim.Op`).
//!
//! **The one import**, approved by the owner for this build alone: `env.zc_panic(ptr, len)`. A
//! panic hands its text to the host, which keeps it for the `bug` diagnostic it shows, and then
//! the module traps. `tools/console_check.mjs` fails if the module asks for anything else. After a
//! trap the instance is poisoned (docs/wasm.md row 9) and the host discards it.
//!
//! This is `ReleaseSafe` when it ships: `ReleaseSmall` removes the assertions the core relies on.

const std = @import("std");
const core = @import("core.zig");
const console_sim = @import("console_sim.zig");

comptime {
    // Zig analyses only what is referenced; this makes the whole of every core module count.
    core.reference_all();
}

/// The host's side of a panic: it records `len` bytes at `ptr` and returns.
extern "env" fn zc_panic(ptr: [*]const u8, len: u32) void;

pub const panic = std.debug.FullPanic(panic_handler);

fn panic_handler(message: []const u8, first_trace_address: ?usize) noreturn {
    _ = first_trace_address;
    const length: u32 = @intCast(@min(message.len, std.math.maxInt(u32)));
    zc_panic(message.ptr, length);
    @trap();
}

var console: ?*console_sim.Console = null;
var request_buffer: [console_sim.frame_bytes_max]u8 = undefined;
var response: @import("api.zig").Response = .{ .status = 0, .request_id = "", .body = "" };

fn live() *console_sim.Console {
    return console.?;
}

export fn zc_init() u32 {
    if (console != null) return 1;
    console = console_sim.Console.create(std.heap.wasm_allocator) catch return 2;
    return 0;
}

export fn zc_request_ptr() [*]u8 {
    return &request_buffer;
}

export fn zc_request(length: u32) u32 {
    std.debug.assert(length <= request_buffer.len);
    response = live().request(request_buffer[0..length]);
    return response.status;
}

export fn zc_response_ptr() [*]const u8 {
    return response.body.ptr;
}

export fn zc_response_len() u32 {
    return @intCast(response.body.len);
}

export fn zc_response_id_ptr() [*]const u8 {
    return response.request_id.ptr;
}

export fn zc_response_id_len() u32 {
    return @intCast(response.request_id.len);
}

export fn zc_response_hold_ms() u32 {
    return response.hold_ms;
}

export fn zc_advance(ms: u32) void {
    live().advance(ms);
}

export fn zc_now_ms() f64 {
    return @floatFromInt(live().now_ms());
}

export fn zc_revision() f64 {
    const revision = live().revision() orelse return -1;
    return @floatFromInt(revision);
}

export fn zc_control(op: u32, arg: u32) i32 {
    const known = std.enums.fromInt(console_sim.Op, op) orelse return -2;
    return live().control(known, arg) catch -3;
}
