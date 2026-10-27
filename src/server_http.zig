//! The HTTP/1.1 front of `zcube-server`: one function per connection (`serve`), run by the server
//! on a thread of its own, and the table and watchdog that keep the connections bounded. Shell
//! code: sockets, threads, a mutex, the real clock.
//!
//! **What a request does.** `/v1/*` goes to the core's `Api.handle` as bytes in, bytes out; `GET /`
//! and `/console/*` are the embedded console (`server_static.zig`). Every reply carries an
//! `X-Request-Id`, the client's if it sent a valid one. A request the shell refuses before the API
//! sees it (head too large, body too large, too many connections or holds) is still the error body
//! of docs/api.md with a registered code, not a bare status line.
//!
//! **The long-poll watch.** `Api.handle` answers what is ready; if nothing is and the client asked
//! to wait, `Response.hold_ms` says the shell may hold the reply (docs/core.md). The shell opens a
//! store watch from the revision it read before asking, waits up to `hold_ms` for a key under the
//! hold prefixes, then asks `handle` again with `timeout=0`, or sends the first (empty) answer on
//! a timeout. At most `http_holds_max` are held at once.
//!
//! **Bounds** (constants.zig): `http_connections_max` connections, `http_head_bytes_max` of head,
//! `http_body_bytes_max` of body, an idle connection closed after `http_idle_timeout_ms` by one
//! watchdog over the connection table, a request arena of `request_arena_bytes_max`.

const std = @import("std");
const assert = std.debug.assert;
const http = std.http;
const net = std.Io.net;
const api_mod = @import("api.zig");
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const Clock = @import("clock.zig").Clock;
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const BoundedArena = @import("server_arena.zig").BoundedArena;
const static = @import("server_static.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const Options = struct {
    /// Log every request, not only failures and writes.
    verbose: bool,
    /// Log failures only.
    quiet: bool,
    /// Log nothing: for tests, where the build runner counts any stderr as a failure.
    silent: bool = false,
};

/// What a connection is doing, for the watchdog: waiting for a client to send or to read is
/// bounded by the idle timeout, working and holding are not (the store has timeouts of its own,
/// and a hold is bounded by its own deadline).
const State = enum { waiting, working, holding, writing };

const Slot = struct {
    mutex: std.Io.Mutex = .init,
    stream: ?net.Stream = null,
    state: State = .waiting,
    since_ms: u64 = 0,
};

/// Slots 0 to `http_connections_max - 1` serve connections; the rest deliver refusals.
const slots_count = constants.http_connections_max + constants.http_refusals_max;

pub const SlotKind = enum { connection, refusal };

/// Everything the connections share.
pub const Shared = struct {
    gpa: Allocator,
    io: std.Io,
    store: store.Store,
    clock: Clock,
    api: api_mod.Api,
    /// Taken by writes only (they move the API's decision source).
    api_mutex: std.Io.Mutex = .init,
    options: Options,
    holds: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    slots: [slots_count]Slot = @splat(.{}),
    slots_mutex: std.Io.Mutex = .init,

    // ---- The connection table ----

    /// Takes a free slot of `kind` for `stream`, or null when they are all in use.
    pub fn take_slot(shared: *Shared, stream: net.Stream, kind: SlotKind) ?u32 {
        shared.slots_mutex.lockUncancelable(shared.io);
        defer shared.slots_mutex.unlock(shared.io);
        const first: usize = if (kind == .connection) 0 else constants.http_connections_max;
        const end: usize = if (kind == .connection) constants.http_connections_max else slots_count;
        for (shared.slots[first..end], first..) |*slot, index| {
            if (slot.stream != null) continue;
            slot.stream = stream;
            slot.state = .waiting;
            slot.since_ms = shared.clock.now_ms();
            return @intCast(index);
        }
        return null;
    }

    /// Frees the slot and closes its stream, under the slot's lock so the watchdog never acts on
    /// a descriptor that has been closed and reused.
    fn release_slot(shared: *Shared, index: u32) void {
        const slot = &shared.slots[index];
        slot.mutex.lockUncancelable(shared.io);
        defer slot.mutex.unlock(shared.io);
        shared.slots_mutex.lockUncancelable(shared.io);
        const stream = slot.stream.?;
        slot.stream = null;
        shared.slots_mutex.unlock(shared.io);
        stream.close(shared.io);
    }

    fn set_state(shared: *Shared, index: u32, state: State) void {
        const slot = &shared.slots[index];
        slot.mutex.lockUncancelable(shared.io);
        defer slot.mutex.unlock(shared.io);
        slot.state = state;
        slot.since_ms = shared.clock.now_ms();
    }

    /// Connections in use.
    pub fn connections(shared: *Shared) u32 {
        shared.slots_mutex.lockUncancelable(shared.io);
        defer shared.slots_mutex.unlock(shared.io);
        var count: u32 = 0;
        for (shared.slots[0..constants.http_connections_max]) |slot| {
            if (slot.stream != null) count += 1;
        }
        return count;
    }

    // ---- The watchdog ----

    /// Runs until cancelled: every `http_watchdog_ms` it shuts down a connection that has been
    /// waiting on its client longer than `http_idle_timeout_ms`. The connection's read or write
    /// then fails and `serve` returns.
    pub fn watchdog(shared: *Shared) void {
        while (true) {
            shared.io.sleep(.fromMilliseconds(constants.http_watchdog_ms), .awake) catch return;
            shared.sweep();
        }
    }

    fn sweep(shared: *Shared) void {
        const now = shared.clock.now_ms();
        for (&shared.slots) |*slot| {
            slot.mutex.lockUncancelable(shared.io);
            defer slot.mutex.unlock(shared.io);
            const stream = slot.stream orelse continue;
            if (slot.state == .working) continue;
            if (slot.state == .holding) continue;
            if (now -| slot.since_ms < constants.http_idle_timeout_ms) continue;
            stream.shutdown(shared.io, .both) catch {}; // Already closing is the goal.
        }
    }

    // ---- The API ----

    /// Reads run side by side (the request counter is atomic); a write also moves the decision
    /// source, so writes take turns.
    fn handle(
        shared: *Shared,
        ctx: *const controller.Context,
        request: api_mod.Request,
    ) api_mod.Response {
        if (is_read(request.method)) return shared.api.handle(ctx, request);
        shared.api_mutex.lockUncancelable(shared.io);
        defer shared.api_mutex.unlock(shared.io);
        return shared.api.handle(ctx, request);
    }

    fn new_id(shared: *Shared, ctx: *const controller.Context) []const u8 {
        return shared.api.assign_id(ctx, .{ .method = "", .path = "" });
    }
};

// ---- One connection ----------------------------------------------------------------------------

/// What one request needs: its arena and diagnostic, reset for each request of the connection.
const Work = struct {
    shared: *Shared,
    slot: u32,
    arena: BoundedArena,
    diag: Diag,

    fn context(work: *Work) controller.Context {
        work.arena.reset();
        work.diag.reset();
        return .{
            .store = work.shared.store,
            .clock = work.shared.clock,
            .arena = work.arena.allocator(),
            .diag = &work.diag,
        };
    }
};

/// Serves one connection until the client leaves, asks to close, goes idle or breaks the
/// protocol. Takes ownership of the slot: it is freed (and the stream closed) here.
pub fn serve(shared: *Shared, slot: u32, stream: net.Stream) void {
    defer shared.release_slot(slot);
    var read_buffer: [constants.http_head_bytes_max]u8 = undefined;
    var write_buffer: [constants.http_write_buffer_bytes]u8 = undefined;
    var reader = stream.reader(shared.io, &read_buffer);
    var writer = stream.writer(shared.io, &write_buffer);
    var connection = http.Server.init(&reader.interface, &writer.interface);
    var work: Work = .{
        .shared = shared,
        .slot = slot,
        .arena = .init(shared.gpa, constants.request_arena_bytes_max),
        .diag = undefined,
    };
    defer work.arena.deinit();
    for (0..constants.http_requests_per_connection_max) |_| {
        shared.set_state(slot, .waiting);
        if (shared.stopping.load(.acquire)) return;
        var request = connection.receiveHead() catch |err| {
            refuse_head(&work, &writer, err);
            return linger(shared, slot, stream, &reader);
        };
        const keep_alive = answer(&work, &request) catch return;
        if (!keep_alive) return linger(shared, slot, stream, &reader);
    }
}

/// Closing a socket that still has unread data makes the kernel send a reset, which can destroy
/// the reply the client has not read yet. So after a reply that ends the connection, stop sending,
/// read what the client still sends (at most `http_linger_bytes_max`; the watchdog ends a client
/// that stalls) and only then close.
fn linger(shared: *Shared, slot: u32, stream: net.Stream, reader: *net.Stream.Reader) void {
    shared.set_state(slot, .waiting);
    stream.shutdown(shared.io, .send) catch return;
    _ = reader.interface.discardShort(constants.http_linger_bytes_max) catch {}; // Gone is fine.
}

const Closed = error{Closed};

/// Answers one request. Returns whether the connection may carry another. `error.Closed` means
/// the client went away or broke the protocol after the response (if any) was written.
fn answer(work: *Work, request: *http.Server.Request) Closed!bool {
    const shared = work.shared;
    shared.set_state(work.slot, .working);
    const started = shared.clock.now_ms();
    const ctx = work.context();
    const parsed = copy_head(&ctx, request) orelse return error.Closed;
    const body = read_body(work, &ctx, request, parsed) catch |err| switch (err) {
        error.Refused => return false,
        error.Closed => return error.Closed,
    };
    if (is_api(parsed.path)) {
        const response = serve_api(work, &ctx, parsed, body);
        return respond_api(work, request, response, started, parsed);
    }
    return respond_static(work, &ctx, request, parsed, started);
}

/// The parts of a request head the handlers need, copied into the arena because reading the body
/// invalidates the head's strings.
const Parsed = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    request_id: ?[]const u8,
    content_length: ?u64,
    chunked: bool,
    has_body_method: bool,
};

fn copy_head(ctx: *const controller.Context, request: *http.Server.Request) ?Parsed {
    const head = request.head;
    const target = ctx.arena.dupe(u8, head.target) catch return null;
    const question = std.mem.findScalar(u8, target, '?');
    var request_id: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "x-request-id")) continue;
        request_id = ctx.arena.dupe(u8, header.value) catch return null;
    }
    return .{
        .method = @tagName(head.method),
        .path = if (question) |at| target[0..at] else target,
        .query = if (question) |at| target[at + 1 ..] else "",
        .request_id = request_id,
        .content_length = head.content_length,
        .chunked = head.transfer_encoding != .none,
        .has_body_method = head.method.requestHasBody(),
    };
}

const BodyError = error{ Refused, Closed };

/// Reads the body into the arena. A body that is too large, or whose length is not announced, is
/// refused with a reply and the connection is closed (`Refused`).
fn read_body(
    work: *Work,
    ctx: *const controller.Context,
    request: *http.Server.Request,
    parsed: Parsed,
) BodyError![]const u8 {
    if (parsed.chunked) {
        const cause = "send a Content-Length: chunked bodies are not accepted";
        refuse_request(work, ctx, request, 411, .E0104, cause);
        return error.Refused;
    }
    const length = parsed.content_length orelse return "";
    if (length > constants.http_body_bytes_max) {
        const cause = "the request body is larger than 65536 bytes";
        refuse_request(work, ctx, request, 413, .E0108, cause);
        return error.Refused;
    }
    const reader = request.readerExpectContinue(&.{}) catch return error.Closed;
    const buffer = ctx.arena.alloc(u8, @intCast(length)) catch return error.Closed;
    reader.readSliceAll(buffer) catch return error.Closed;
    return buffer;
}

fn is_read(method: []const u8) bool {
    if (std.mem.eql(u8, method, "GET")) return true;
    return std.mem.eql(u8, method, "HEAD");
}

fn is_api(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/v1")) return true;
    return std.mem.startsWith(u8, path, "/v1/");
}

// ---- The API ------------------------------------------------------------------------------------

fn serve_api(
    work: *Work,
    ctx: *const controller.Context,
    parsed: Parsed,
    body: []const u8,
) api_mod.Response {
    const shared = work.shared;
    const request: api_mod.Request = .{
        .method = parsed.method,
        .path = parsed.path,
        .query = parsed.query,
        .request_id = parsed.request_id,
        .body = body,
    };
    const before = revision_now(ctx);
    const first = shared.handle(ctx, request);
    if (first.hold_ms == 0) return first;
    if (first.status != 200) return first;
    const from = (before orelse return first) + 1;
    shared.set_state(work.slot, .holding);
    if (shared.holds.fetchAdd(1, .acq_rel) >= constants.http_holds_max) {
        _ = shared.holds.fetchSub(1, .acq_rel);
        return refuse_response(shared, ctx, 503, .E0108, "too many watches are waiting at once");
    }
    defer _ = shared.holds.fetchSub(1, .acq_rel);
    if (!wait_for_change(shared, first, from)) return first;
    var again = request;
    again.hold = false;
    return shared.handle(ctx, again);
}

/// The store's revision now, or null if the store cannot be read (the handler will say why).
fn revision_now(ctx: *const controller.Context) ?store.Revision {
    const status = ctx.store.status(ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
    return status.revision;
}

/// Holds for up to `first.hold_ms` for a change under `first.hold_prefixes` after `from - 1`.
/// True: ask the handler again (a change, or anything that needs the handler to say). False: the
/// time is up, or the server is stopping, and `first` is the answer.
fn wait_for_change(shared: *Shared, first: api_mod.Response, from: store.Revision) bool {
    var diag: Diag = undefined;
    diag.reset();
    var arena = BoundedArena.init(shared.gpa, constants.request_arena_bytes_max);
    defer arena.deinit();
    const options: store.WatchOptions = .{ .prefix = "", .from_revision = from };
    var watch = shared.store.watch(options, &diag) catch return true;
    defer watch.close();
    const deadline = shared.clock.now_ms() + first.hold_ms;
    while (!shared.stopping.load(.acquire)) {
        const began = shared.clock.now_ms();
        if (began >= deadline) return false;
        const slice: u32 = @intCast(@min(deadline - began, constants.http_hold_slice_ms));
        arena.reset();
        const batch = watch.next(arena.allocator(), slice, &diag) catch return true;
        for (batch.events) |event| {
            if (matches(first.hold_prefixes, event.kv.key)) return true;
        }
        // A store that does not wait (the memory store) answers at once: do not spin on it.
        const waited = shared.clock.now_ms() -| began;
        if (waited >= slice) continue;
        const nap = @min(slice - waited, constants.server_poll_ms);
        shared.io.sleep(.fromMilliseconds(nap), .awake) catch return false;
    }
    return false;
}

fn matches(prefixes: []const []const u8, key: []const u8) bool {
    if (prefixes.len == 0) return true;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, key, prefix)) return true;
    }
    return false;
}

const json_headers = [_]http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
};

fn respond_api(
    work: *Work,
    request: *http.Server.Request,
    response: api_mod.Response,
    started_ms: u64,
    parsed: Parsed,
) Closed!bool {
    const shared = work.shared;
    shared.set_state(work.slot, .writing);
    const headers = json_headers ++ [_]http.Header{
        .{ .name = "x-request-id", .value = response.request_id },
    };
    const status = std.enums.fromInt(http.Status, response.status) orelse .internal_server_error;
    request.respond(response.body, .{ .status = status, .extra_headers = &headers }) catch {
        return error.Closed;
    };
    log_request(shared, parsed, response.request_id, response.status, started_ms);
    return request.head.keep_alive;
}

/// A reply made by the shell: the failure raised on `ctx.diag`, in the API's error body.
fn refuse_response(
    shared: *Shared,
    ctx: *const controller.Context,
    status: u16,
    code: codes.Code,
    cause: []const u8,
) api_mod.Response {
    ctx.diag.reset();
    ctx.diag.raise(code);
    ctx.diag.cause("{s}", .{cause});
    ctx.diag.fix(.{ .sentence = "try again shortly, or send a smaller request" });
    return api_mod.refusal(ctx, shared.new_id(ctx), status);
}

/// Replies with a refusal and tells the client the connection is closing.
fn refuse_request(
    work: *Work,
    ctx: *const controller.Context,
    request: *http.Server.Request,
    status: u16,
    code: codes.Code,
    cause: []const u8,
) void {
    const response = refuse_response(work.shared, ctx, status, code, cause);
    const headers = json_headers ++ [_]http.Header{
        .{ .name = "x-request-id", .value = response.request_id },
    };
    const code_status = std.enums.fromInt(http.Status, status) orelse .internal_server_error;
    request.respond(response.body, .{
        .status = code_status,
        .keep_alive = false,
        .extra_headers = &headers,
    }) catch {}; // The client is gone; nothing more to do.
}

// ---- The console --------------------------------------------------------------------------------

/// The page's rules, so that "no request to any host but the server's own" holds even if the page
/// is ever edited wrong: the browser refuses what it forbids.
const content_policy =
    "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; " ++
    "script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'; object-src 'none'; " ++
    "base-uri 'self'; frame-ancestors 'none'";

fn serve_asset(
    work: *Work,
    request: *http.Server.Request,
    asset: static.Asset,
    parsed: Parsed,
    started_ms: u64,
) Closed!bool {
    work.shared.set_state(work.slot, .writing);
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = asset.content_type },
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "content-security-policy", .value = content_policy },
    };
    request.respond(asset.bytes, .{ .extra_headers = &headers }) catch return error.Closed;
    log_request(work.shared, parsed, "-", 200, started_ms);
    return request.head.keep_alive;
}

fn respond_static(
    work: *Work,
    ctx: *const controller.Context,
    request: *http.Server.Request,
    parsed: Parsed,
    started_ms: u64,
) Closed!bool {
    const shared = work.shared;
    const found = static.find(parsed.path);
    if (found) |asset| {
        if (is_read(parsed.method)) return serve_asset(work, request, asset, parsed, started_ms);
    }
    ctx.diag.reset();
    const status: u16 = if (found != null) 405 else 404;
    if (found != null) {
        ctx.diag.raise(.E0104);
        ctx.diag.cause("method: the console is read with GET", .{});
    } else {
        ctx.diag.raise(.E0101);
        ctx.diag.cause("nothing is served at {s}", .{parsed.path});
    }
    ctx.diag.fix(.{
        .sentence = "the console is at /, the API under /v1/",
        .command = "GET /v1/status",
    });
    const response = api_mod.refusal(ctx, shared.new_id(ctx), status);
    return respond_api(work, request, response, started_ms, parsed);
}

/// A task for a connection the server will not serve (too many open): tells the client why, stops
/// sending, reads what the client still sends so that the close is not a reset that eats the
/// reply, and closes. It holds a refusal slot, so the watchdog ends it if the client stalls.
pub fn serve_refusal(shared: *Shared, slot: u32, stream: net.Stream, cause: []const u8) void {
    defer shared.release_slot(slot);
    refuse_stream(shared, stream, cause);
    stream.shutdown(shared.io, .send) catch return;
    var buffer: [1024]u8 = undefined;
    var reader = stream.reader(shared.io, &buffer);
    _ = reader.interface.discardShort(constants.http_linger_bytes_max) catch {}; // Gone is fine.
}

fn refuse_stream(shared: *Shared, stream: net.Stream, cause: []const u8) void {
    var arena = BoundedArena.init(shared.gpa, 64 * 1024);
    defer arena.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const ctx: controller.Context = .{
        .store = shared.store,
        .clock = shared.clock,
        .arena = arena.allocator(),
        .diag = &diag,
    };
    const response = refuse_response(shared, &ctx, 503, .E0108, cause);
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(shared.io, &buffer);
    write_raw(&writer.interface, response);
}

/// Frees a slot taken by `take_slot` whose connection never started, closing its stream.
pub fn release(shared: *Shared, slot: u32) void {
    shared.release_slot(slot);
}

// ---- Refusals before there is a request ---------------------------------------------------------

/// The head could not be read: answer the ones that deserve an answer, then close.
fn refuse_head(work: *Work, writer: *net.Stream.Writer, err: http.Server.ReceiveHeadError) void {
    const status: u16 = switch (err) {
        error.HttpHeadersOversize => 431,
        error.HttpHeadersInvalid => 400,
        error.HttpRequestTruncated, error.HttpConnectionClosing, error.ReadFailed => return,
    };
    const ctx = work.context();
    const big = "the request head is larger than 16384 bytes";
    const invalid = "the request head is not valid HTTP/1.1";
    const response = if (status == 431)
        refuse_response(work.shared, &ctx, status, .E0108, big)
    else
        refuse_response(work.shared, &ctx, status, .E0104, invalid);
    write_raw(&writer.interface, response);
}

/// Writes a complete reply without an `http.Server.Request`: for a connection that has none yet.
pub fn write_raw(out: *std.Io.Writer, response: api_mod.Response) void {
    const phrase = if (std.enums.fromInt(http.Status, response.status)) |status|
        status.phrase() orelse ""
    else
        "";
    out.print(
        "HTTP/1.1 {d} {s}\r\ncontent-type: application/json\r\ncache-control: no-store\r\n" ++
            "x-request-id: {s}\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
        .{ response.status, phrase, response.request_id, response.body.len },
    ) catch return;
    out.writeAll(response.body) catch return;
    out.flush() catch return; // The client is gone; there is nobody to tell.
}

// ---- Logging ------------------------------------------------------------------------------------

/// One line per request that matters: failures and writes always, everything with `verbose`,
/// failures only with `quiet`. The request id is the thread between a client's error and this log.
fn log_request(
    shared: *Shared,
    parsed: Parsed,
    request_id: []const u8,
    status: u16,
    started_ms: u64,
) void {
    if (shared.options.silent) return;
    if (status < 400) {
        if (shared.options.quiet) return;
        if (!shared.options.verbose) {
            if (is_read(parsed.method)) return;
        }
    }
    var buffer: [512]u8 = undefined;
    const took = shared.clock.now_ms() -| started_ms;
    const line = std.fmt.bufPrint(&buffer, "{s} {s} {s} -> {d} ({d} ms)\n", .{
        request_id, parsed.method, parsed.path[0..@min(parsed.path.len, 200)], status, took,
    }) catch return;
    std.Io.File.stderr().writeStreamingAll(shared.io, line) catch {}; // Nowhere else to report it.
}

const testing = std.testing;

test "a key matches a hold when it is under one of its prefixes, or when there are none" {
    // Goal: which changes end a hold. Method: no prefixes, one, two.
    try testing.expect(matches(&.{}, "/anything"));
    try testing.expect(matches(&.{"/services/"}, "/services/hello"));
    try testing.expect(!matches(&.{"/services/"}, "/replicas/hello/1"));
    try testing.expect(matches(&.{ "/services/", "/replicas/" }, "/replicas/hello/1"));
}

test "the API is anything under /v1" {
    // Goal: the console and the API do not overlap. Method: the edges of the prefix.
    try testing.expect(is_api("/v1"));
    try testing.expect(is_api("/v1/status"));
    try testing.expect(!is_api("/v10"));
    try testing.expect(!is_api("/"));
    try testing.expect(!is_api("/console/v1/x"));
}
