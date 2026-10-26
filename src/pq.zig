//! A thin, checked layer over libpq for the Postgres store backend: connecting, running one
//! statement with binary parameters, reading binary results, and turning every failure into a
//! registered `ZC-E02xx` diagnostic. Nothing above this file sees a libpq type except the
//! connection pointer, and nothing outside it formats libpq's text for the user.
//!
//! ## Binary protocol
//!
//! Parameters and results use the binary format, so a value (which may hold any byte) and a
//! number never go through text. The cost is that every parameter names its type (`Oid`) and
//! every result column is decoded by width: `int8` is eight big-endian bytes, `bool` one byte.
//!
//! ## Failures
//!
//! `classify_connect` and `classify_state` are the two places that decide which diagnostic a
//! libpq failure becomes; both are pure and tested with canned messages. libpq gives a failed
//! connection attempt no SQLSTATE, only text, so that one function matches on the English
//! fragments Postgres and libpq use (see its doc). The raw message is always the first cause, so
//! a misjudged class still shows the operator what Postgres said; the last cause, the one default
//! output shows, is written for the operator and carries no libpq text.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("libpq_c");
const constants = @import("constants.zig");
const Diag = @import("diag.zig").Diag;

pub const Error = error{BackendFailed};

/// The type of a parameter, as Postgres numbers them.
pub const Oid = enum(c.Oid) {
    bool = 16,
    bytea = 17,
    int8 = 20,
    int4 = 23,
    text = 25,
};

pub const params_max = 40;

/// The parameters of one statement. Built in place and not moved afterwards: each value points
/// into the struct (a number) or into the caller's bytes, which must outlive the call.
pub const Params = struct {
    count: u32 = 0,
    types: [params_max]c.Oid = undefined,
    values: [params_max][*c]const u8 = undefined,
    lengths: [params_max]c_int = undefined,
    formats: [params_max]c_int = undefined,
    numbers: [params_max][8]u8 = undefined,

    fn slot(params: *Params, oid: Oid) u32 {
        assert(params.count < params_max);
        const index = params.count;
        params.count += 1;
        params.types[index] = @backingInt(oid);
        params.formats[index] = 1;
        return index;
    }

    pub fn add_int8(params: *Params, value: u64) void {
        assert(value <= std.math.maxInt(i64));
        const index = params.slot(.int8);
        std.mem.writeInt(i64, &params.numbers[index], @intCast(value), .big);
        params.values[index] = &params.numbers[index];
        params.lengths[index] = 8;
    }

    pub fn add_int4(params: *Params, value: u32) void {
        assert(value <= std.math.maxInt(i32));
        const index = params.slot(.int4);
        std.mem.writeInt(i32, params.numbers[index][0..4], @intCast(value), .big);
        params.values[index] = &params.numbers[index];
        params.lengths[index] = 4;
    }

    /// `oid` is `.text` or `.bytea`; both are raw bytes in the binary format.
    pub fn add_bytes(params: *Params, oid: Oid, bytes: []const u8) void {
        assert(oid != .int8);
        assert(oid != .int4);
        assert(oid != .bool);
        assert(bytes.len <= std.math.maxInt(i32));
        const index = params.slot(oid);
        params.values[index] = bytes.ptr; // A slice's pointer is never null, even when empty.
        params.lengths[index] = @intCast(bytes.len);
    }

    pub fn add_null(params: *Params, oid: Oid) void {
        const index = params.slot(oid);
        params.values[index] = null;
        params.lengths[index] = 0;
    }

    pub fn add_optional_text(params: *Params, bytes: ?[]const u8) void {
        if (bytes) |present| {
            params.add_bytes(.text, present);
        } else {
            params.add_null(.text);
        }
    }

    pub fn add_optional_int8(params: *Params, value: ?u64) void {
        if (value) |present| {
            params.add_int8(present);
        } else {
            params.add_null(.int8);
        }
    }
};

/// One statement's answer. Column values are valid until `clear`.
pub const Result = struct {
    raw: *c.PGresult,

    pub fn clear(result: *Result) void {
        c.PQclear(result.raw);
        result.* = undefined;
    }

    pub fn rows(result: *const Result) u32 {
        return @intCast(c.PQntuples(result.raw));
    }

    pub fn is_null(result: *const Result, row: u32, column: u32) bool {
        assert(row < result.rows());
        return c.PQgetisnull(result.raw, @intCast(row), @intCast(column)) != 0;
    }

    /// The column's bytes. A `text` or `bytea` column; a number is read with `int8` or `int4`.
    pub fn bytes(result: *const Result, row: u32, column: u32) []const u8 {
        assert(!result.is_null(row, column));
        const length: usize = @intCast(c.PQgetlength(result.raw, @intCast(row), @intCast(column)));
        if (length == 0) return &.{};
        const pointer = c.PQgetvalue(result.raw, @intCast(row), @intCast(column));
        return @as([*]const u8, @ptrCast(pointer))[0..length];
    }

    pub fn int8(result: *const Result, row: u32, column: u32) i64 {
        const raw = result.bytes(row, column);
        assert(raw.len == 8); // The server sends the width of the column's type.
        return std.mem.readInt(i64, raw[0..8], .big);
    }

    pub fn unsigned(result: *const Result, row: u32, column: u32) u64 {
        const value = result.int8(row, column);
        assert(value >= 0);
        return @intCast(value);
    }

    pub fn int4(result: *const Result, row: u32, column: u32) i32 {
        const raw = result.bytes(row, column);
        assert(raw.len == 4);
        return std.mem.readInt(i32, raw[0..4], .big);
    }

    pub fn boolean(result: *const Result, row: u32, column: u32) bool {
        const raw = result.bytes(row, column);
        assert(raw.len == 1);
        assert(raw[0] <= 1);
        return raw[0] == 1;
    }

    /// Rows a command changed (the count in its command tag); 0 for a SELECT.
    pub fn affected(result: *const Result) u32 {
        const text = std.mem.sliceTo(c.PQcmdTuples(result.raw), 0);
        if (text.len == 0) return 0;
        return std.fmt.parseInt(u32, text, 10) catch 0; // A tag is digits; 0 is only a guess.
    }
};

/// A statement text under construction, in a fixed buffer, NUL-terminated for libpq. For the few
/// statements whose shape depends on the request (the compares of a transaction).
pub fn SqlBuffer(comptime capacity: u32) type {
    return struct {
        const Self = @This();
        bytes: [capacity + 1]u8 = undefined,
        len: u32 = 0,

        pub fn append(buffer: *Self, text: []const u8) void {
            assert(buffer.len + text.len <= capacity);
            @memcpy(buffer.bytes[buffer.len..][0..text.len], text);
            buffer.len += @intCast(text.len);
        }

        pub fn append_number(buffer: *Self, value: u32) void {
            var digits: [10]u8 = undefined;
            // A u32 has at most ten digits, so the buffer always fits.
            const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch unreachable;
            buffer.append(text);
        }

        pub fn terminated(buffer: *Self) [:0]const u8 {
            buffer.bytes[buffer.len] = 0;
            return buffer.bytes[0..buffer.len :0];
        }

        /// For a buffer already finished with `terminated`.
        pub fn terminated_const(buffer: *const Self) [:0]const u8 {
            assert(buffer.bytes[buffer.len] == 0);
            return buffer.bytes[0..buffer.len :0];
        }
    };
}

fn ignore_notice(_: ?*anyopaque, _: ?*const c.PGresult) callconv(.c) void {}

// ---- Connecting --------------------------------------------------------------------------------

/// Opens a connection and runs `setup_sql` on it (the session's settings). The settings of
/// `conninfo` are libpq's (a keyword/value string or a URI); ours follow it and win: a connect
/// timeout, and the application name that `pg_stat_activity` shows an operator.
pub fn connect(diag: *Diag, conninfo: [:0]const u8, setup_sql: [:0]const u8) Error!*c.PGconn {
    assert(diag.code == null);
    assert(conninfo.len > 0);
    var timeout_text: [16]u8 = undefined;
    const timeout = std.fmt.bufPrintSentinel(&timeout_text, "{d}", .{
        constants.store_postgres_connect_timeout_s,
    }, 0) catch unreachable; // A u32 is at most ten digits.
    const keywords = [_:null]?[*:0]const u8{ "dbname", "connect_timeout", "application_name" };
    const values = [_:null]?[*:0]const u8{ conninfo.ptr, timeout.ptr, "zcube-store" };
    const raw = c.PQconnectdbParams(@ptrCast(&keywords), @ptrCast(&values), 1) orelse {
        return fail_no_memory(diag);
    };
    if (c.PQstatus(raw) != c.CONNECTION_OK) {
        const failure = fail_connect(diag, raw);
        c.PQfinish(raw);
        return failure;
    }
    _ = c.PQsetNoticeReceiver(raw, ignore_notice, null); // The previous receiver: none to restore.
    var result = exec_simple(diag, raw, setup_sql, .{}) catch |err| {
        c.PQfinish(raw);
        return err;
    };
    result.clear();
    assert(c.PQstatus(raw) == c.CONNECTION_OK);
    return raw;
}

pub fn is_open(conn: *c.PGconn) bool {
    return c.PQstatus(conn) == c.CONNECTION_OK;
}

pub fn close(conn: *c.PGconn) void {
    c.PQfinish(conn);
}

/// The socket to wait on for a notification.
pub fn socket(conn: *c.PGconn) c_int {
    const descriptor = c.PQsocket(conn);
    assert(descriptor >= 0);
    return descriptor;
}

/// Reads whatever the server has sent. False if the connection is gone.
pub fn consume(conn: *c.PGconn) bool {
    return c.PQconsumeInput(conn) == 1;
}

/// Takes one queued notification, if any. Call `consume` first to read the socket.
pub fn take_notification(conn: *c.PGconn) bool {
    const notice = c.PQnotifies(conn) orelse return false;
    c.PQfreemem(notice);
    return true;
}

pub fn in_transaction(conn: *c.PGconn) bool {
    return c.PQtransactionStatus(conn) != c.PQTRANS_IDLE;
}

// ---- Running a statement -----------------------------------------------------------------------

/// What `exec` needs to word a failure.
pub const Context = struct {
    /// The statement is a COMMIT: if the connection drops during it, the write may have applied.
    committing: bool = false,
    /// The lock wait the session was configured with, for the "busy" cause.
    lock_timeout_ms: u32 = constants.store_postgres_lock_timeout_ms,
};

/// Runs one statement on the extended protocol: typed parameters, and every result column in the
/// binary format. A statement with no parameters passes an empty `Params`.
pub fn exec(
    diag: *Diag,
    conn: *c.PGconn,
    sql: [:0]const u8,
    params: *const Params,
    context: Context,
) Error!Result {
    assert(diag.code == null);
    const raw = c.PQexecParams(
        conn,
        sql.ptr,
        @intCast(params.count),
        &params.types,
        &params.values,
        &params.lengths,
        &params.formats,
        1,
    );
    return finish(diag, conn, raw, context);
}

/// Runs text on the simple protocol, which allows several statements (the schema, the session
/// settings) and BEGIN/COMMIT. Results come back as text, so it is for statements that return
/// nothing the caller reads.
pub fn exec_simple(diag: *Diag, conn: *c.PGconn, sql: [:0]const u8, context: Context) Error!Result {
    assert(diag.code == null);
    return finish(diag, conn, c.PQexec(conn, sql.ptr), context);
}

fn finish(diag: *Diag, conn: *c.PGconn, raw: ?*c.PGresult, context: Context) Error!Result {
    const status = if (raw) |present| c.PQresultStatus(present) else c.PGRES_FATAL_ERROR;
    switch (status) {
        c.PGRES_TUPLES_OK, c.PGRES_COMMAND_OK => return .{ .raw = raw.? },
        else => {
            const failure = fail_result(diag, conn, raw, context);
            if (raw) |present| c.PQclear(present);
            return failure;
        },
    }
}

/// Ends the open transaction, if any, discarding it. False if the connection could not be
/// brought back to idle, in which case it must be closed.
pub fn rollback(conn: *c.PGconn) bool {
    if (c.PQtransactionStatus(conn) == c.PQTRANS_IDLE) return true;
    if (c.PQexec(conn, "ROLLBACK")) |result| c.PQclear(result);
    return c.PQtransactionStatus(conn) == c.PQTRANS_IDLE;
}

// ---- Failures ----------------------------------------------------------------------------------

pub const Class = enum {
    /// No server answered, or the connection settings do not parse.
    unreachable_server,
    credentials,
    database_missing,
    /// The connection ended during an operation.
    dropped,
    /// A lock timeout, a deadlock or a serialisation failure.
    busy,
    /// A table or column the store needs is missing, or the data is corrupt.
    damaged,
    failed,
};

/// Which class a failed connection attempt is, from libpq's message. A failed attempt has no
/// SQLSTATE, so this matches on the fragments Postgres and libpq use in English; a server in
/// another language falls through to `unreachable_server`, whose first cause still shows its text.
pub fn classify_connect(message: []const u8) Class {
    const credentials = [_][]const u8{
        "authentication failed",
        "no pg_hba.conf entry",
        "no password supplied",
        "password is required",
        "is not permitted to log in",
    };
    for (credentials) |fragment| {
        if (std.mem.indexOf(u8, message, fragment) != null) return .credentials;
    }
    if (std.mem.indexOf(u8, message, "role \"") != null) {
        if (std.mem.indexOf(u8, message, "does not exist") != null) return .credentials;
    }
    if (std.mem.indexOf(u8, message, "database \"") != null) {
        if (std.mem.indexOf(u8, message, "does not exist") != null) return .database_missing;
    }
    return .unreachable_server;
}

/// Which class an SQLSTATE is (https://www.postgresql.org/docs/16/errcodes-appendix.html).
/// `connection_lost` is what libpq says about the connection itself, which wins over the code.
pub fn classify_state(sqlstate: []const u8, connection_lost: bool) Class {
    if (connection_lost) return .dropped;
    const exact_busy = [_][]const u8{ "55P03", "57014", "40001", "40P01" };
    for (exact_busy) |code| {
        if (std.mem.eql(u8, sqlstate, code)) return .busy;
    }
    const exact_dropped = [_][]const u8{ "57P01", "57P02", "57P03" };
    for (exact_dropped) |code| {
        if (std.mem.eql(u8, sqlstate, code)) return .dropped;
    }
    const exact_damaged = [_][]const u8{ "42P01", "42703", "XX001", "XX002" };
    for (exact_damaged) |code| {
        if (std.mem.eql(u8, sqlstate, code)) return .damaged;
    }
    if (std.mem.eql(u8, sqlstate, "3D000")) return .database_missing;
    if (std.mem.startsWith(u8, sqlstate, "08")) return .dropped;
    if (std.mem.startsWith(u8, sqlstate, "28")) return .credentials;
    return .failed;
}

/// The first line of libpq's message, which ends in newlines and may span several lines.
pub fn first_line(message: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, message, '\n') orelse message.len;
    return std.mem.trim(u8, message[0..end], " \r");
}

fn cstring(pointer: [*c]const u8, fallback: []const u8) []const u8 {
    if (pointer == null) return fallback;
    const text = std.mem.sliceTo(pointer, 0);
    if (text.len == 0) return fallback;
    return text;
}

/// Where a connection points, for the causes and context of a diagnostic.
const Target = struct {
    host: []const u8,
    port: []const u8,
    database: []const u8,
    user: []const u8,

    fn of(conn: *const c.PGconn) Target {
        return .{
            .host = cstring(c.PQhost(conn), "the local socket"),
            .port = cstring(c.PQport(conn), "5432"),
            .database = cstring(c.PQdb(conn), "(default)"),
            .user = cstring(c.PQuser(conn), "(default)"),
        };
    }
};

fn fail_no_memory(diag: *Diag) Error {
    assert(diag.code == null);
    diag.raise(.E0202);
    diag.cause("libpq could not allocate a connection", .{});
    diag.cause("the server is out of memory", .{});
    diag.fix(.{ .sentence = "free memory on the server, then retry; nothing was changed" });
    return error.BackendFailed;
}

fn fail_connect(diag: *Diag, conn: *const c.PGconn) Error {
    const message = first_line(std.mem.sliceTo(c.PQerrorMessage(conn), 0));
    const target = Target.of(conn);
    return fill(diag, classify_connect(message), message, target, .{});
}

fn fail_result(diag: *Diag, conn: *c.PGconn, result: ?*c.PGresult, context: Context) Error {
    const lost = c.PQstatus(conn) != c.CONNECTION_OK;
    var state: []const u8 = "";
    var message = first_line(std.mem.sliceTo(c.PQerrorMessage(conn), 0));
    if (result) |present| {
        const code = c.PQresultErrorField(present, c.PG_DIAG_SQLSTATE);
        if (code != null) state = std.mem.sliceTo(code, 0);
        const text = first_line(std.mem.sliceTo(c.PQresultErrorMessage(present), 0));
        if (text.len > 0) message = text;
    }
    if (message.len == 0) message = "no message";
    const class = classify_state(state, lost);
    return fill(diag, class, message, Target.of(conn), .{
        .sqlstate = state,
        .committing = context.committing,
        .lock_timeout_ms = context.lock_timeout_ms,
    });
}

const Detail = struct {
    sqlstate: []const u8 = "",
    committing: bool = false,
    lock_timeout_ms: u32 = constants.store_postgres_lock_timeout_ms,
};

/// Fills the diagnostic for a class. The raw message is the first cause; the operator's cause
/// comes last. Context keys fit the renderer's label column (`diag_key_bytes_max`).
fn fill(diag: *Diag, class: Class, message: []const u8, target: Target, detail: Detail) Error {
    assert(diag.code == null);
    assert(message.len > 0);
    switch (class) {
        .unreachable_server => fill_unreachable(diag, message, target),
        .credentials => fill_credentials(diag, message, target),
        .database_missing => fill_database_missing(diag, message, target),
        .dropped => fill_dropped(diag, message, detail),
        .busy => fill_busy(diag, message, detail),
        .damaged => fill_damaged(diag, message, detail),
        .failed => fill_failed(diag, message, detail),
    }
    assert(diag.code != null);
    assert(diag.causes.count >= 2);
    assert(diag.fixes.count >= 1);
    diag.context("host", "{s}", .{target.host});
    diag.context("port", "{s}", .{target.port});
    diag.context("db", "{s}", .{target.database});
    return error.BackendFailed;
}

fn fill_unreachable(diag: *Diag, message: []const u8, target: Target) void {
    diag.raise(.E0201);
    diag.cause("libpq reported: {s}", .{message});
    diag.cause("the Postgres server at {s} port {s} did not accept a connection", .{
        target.host, target.port,
    });
    diag.fix(.{ .sentence = "start Postgres, or correct the host and port in the store settings" });
    diag.fix_with("check that it is accepting connections", "pg_isready -h {s} -p {s}", .{
        target.host, target.port,
    });
}

fn fill_credentials(diag: *Diag, message: []const u8, target: Target) void {
    diag.raise(.E0211);
    diag.cause("libpq reported: {s}", .{message});
    diag.cause("Postgres at {s} did not let the role {s} in", .{ target.host, target.user });
    diag.fix(.{ .sentence = "correct the user and password in the store settings" });
    diag.fix_with("try the same settings by hand", "psql -h {s} -p {s} -U {s} -d {s}", .{
        target.host, target.port, target.user, target.database,
    });
    diag.context("user", "{s}", .{target.user});
}

fn fill_database_missing(diag: *Diag, message: []const u8, target: Target) void {
    diag.raise(.E0212);
    diag.cause("libpq reported: {s}", .{message});
    diag.cause("Postgres at {s} has no database named {s}", .{ target.host, target.database });
    diag.fix(.{ .sentence = "create the database, or correct its name in the store settings" });
    diag.fix_with("create it", "createdb -h {s} -p {s} -U {s} {s}", .{
        target.host, target.port, target.user, target.database,
    });
}

fn fill_dropped(diag: *Diag, message: []const u8, detail: Detail) void {
    diag.raise(.E0213);
    diag.cause("libpq reported: {s}", .{message});
    if (detail.committing) {
        diag.cause("the connection dropped during the commit; the write may or may not apply", .{});
        diag.fix(.{ .sentence = "read the keys back before repeating the write" });
    } else {
        diag.cause("the connection to Postgres dropped; nothing was changed", .{});
        diag.fix(.{ .sentence = "retry once Postgres is back; the store reconnects by itself" });
    }
}

fn fill_busy(diag: *Diag, message: []const u8, detail: Detail) void {
    diag.raise(.E0208);
    diag.cause("libpq reported: {s}", .{message});
    diag.cause(
        "another transaction held a lock for over {d} ms, or Postgres ended this one to resolve " ++
            "a conflict",
        .{detail.lock_timeout_ms},
    );
    diag.fix(.{ .sentence = "find the session that holds a transaction open, stop it, and retry" });
    diag.fix(.{
        .sentence = "see what each session is doing",
        .command = "psql -c \"SELECT pid, state, query FROM pg_stat_activity\"",
    });
}

fn fill_damaged(diag: *Diag, message: []const u8, detail: Detail) void {
    diag.raise(.E0209);
    diag.cause("libpq reported: {s}", .{message});
    diag.cause("a table or column that the store needs is missing or unreadable", .{});
    diag.fix(.{ .sentence = "restore the database from a backup, or use another schema" });
    if (detail.sqlstate.len > 0) diag.context("state", "{s}", .{detail.sqlstate});
}

fn fill_failed(diag: *Diag, message: []const u8, detail: Detail) void {
    diag.raise(.E0202);
    diag.cause("Postgres reported: {s} (SQLSTATE {s})", .{ message, detail.sqlstate });
    diag.cause("{s}", .{failed_cause(detail.sqlstate)});
    diag.fix(.{ .sentence = "fix that condition, then retry; nothing was changed" });
}

fn failed_cause(sqlstate: []const u8) []const u8 {
    if (std.mem.eql(u8, sqlstate, "53100")) return "the disk holding the database is full";
    if (std.mem.eql(u8, sqlstate, "53200")) return "the Postgres server is out of memory";
    if (std.mem.eql(u8, sqlstate, "53300")) return "the Postgres server has no free connections";
    if (std.mem.eql(u8, sqlstate, "25006")) return "the database is read-only (a replica?)";
    if (std.mem.eql(u8, sqlstate, "42501")) return "the role may not do this in the store schema";
    return "the database refused the operation";
}

// ---- Tests -------------------------------------------------------------------------------------

const testing = std.testing;

test "a failed connection attempt is classified from libpq's message" {
    // Goal: the one mapping from a connect failure to a diagnostic class. Method: the messages
    // Postgres 16 sends, wrapped as libpq wraps them, one per class, and an unknown one.
    const refused = "connection to server at \"127.0.0.1\", port 5432 failed: Connection refused";
    try testing.expectEqual(Class.unreachable_server, classify_connect(refused));
    const wrong_password = "connection to server at \"db\" failed: FATAL:  password " ++
        "authentication failed for user \"zcube\"";
    try testing.expectEqual(Class.credentials, classify_connect(wrong_password));
    const no_rule = "FATAL:  no pg_hba.conf entry for host \"10.0.0.7\", user \"zcube\"";
    try testing.expectEqual(Class.credentials, classify_connect(no_rule));
    const no_role = "FATAL:  role \"zc\" does not exist";
    try testing.expectEqual(Class.credentials, classify_connect(no_role));
    const no_database = "FATAL:  database \"zcube_prod\" does not exist";
    try testing.expectEqual(Class.database_missing, classify_connect(no_database));
    try testing.expectEqual(Class.unreachable_server, classify_connect("timeout expired"));
    const bad_syntax = "missing \"=\" after \"x\" in connection info string";
    try testing.expectEqual(Class.unreachable_server, classify_connect(bad_syntax));
}

test "an SQLSTATE is classified, and a lost connection wins over it" {
    // Goal: the one mapping from SQLSTATEs to diagnostic classes. Method: a code of each class,
    // the class prefixes, and the same code with the connection reported lost.
    try testing.expectEqual(Class.busy, classify_state("55P03", false)); // lock_timeout
    try testing.expectEqual(Class.busy, classify_state("57014", false)); // statement_timeout
    try testing.expectEqual(Class.busy, classify_state("40001", false));
    try testing.expectEqual(Class.busy, classify_state("40P01", false));
    try testing.expectEqual(Class.dropped, classify_state("57P01", false)); // admin_shutdown
    try testing.expectEqual(Class.dropped, classify_state("08006", false));
    try testing.expectEqual(Class.damaged, classify_state("42P01", false));
    try testing.expectEqual(Class.database_missing, classify_state("3D000", false));
    try testing.expectEqual(Class.credentials, classify_state("28P01", false));
    try testing.expectEqual(Class.failed, classify_state("53100", false));
    try testing.expectEqual(Class.failed, classify_state("", false));
    try testing.expectEqual(Class.dropped, classify_state("55P03", true));
    try testing.expectEqual(Class.dropped, classify_state("", true));
}

test "the first line of a libpq message is what a cause shows" {
    // Goal: a multi-line message never breaks the rendering. Method: libpq's trailing newline and
    // a message with a detail line.
    try testing.expectEqualStrings("boom", first_line("boom\n"));
    try testing.expectEqualStrings("a", first_line("a\nDETAIL: b\n"));
    try testing.expectEqualStrings("", first_line(""));
}

test "parameters keep their type, width and nulls" {
    // Goal: the binary encoding is exact. Method: one of each kind, read back from the arrays.
    var params: Params = .{};
    params.add_int8(0x0102030405060708);
    params.add_int4(7);
    params.add_bytes(.text, "/k");
    params.add_bytes(.bytea, "");
    params.add_optional_text(null);
    params.add_optional_int8(null);
    try testing.expectEqual(@as(u32, 6), params.count);
    try testing.expectEqual(@as(c_int, 8), params.lengths[0]);
    try testing.expectEqual(@as(u8, 1), params.values[0][0]);
    try testing.expectEqual(@as(u8, 8), params.values[0][7]);
    try testing.expectEqual(@as(c_int, 4), params.lengths[1]);
    try testing.expectEqual(@as(u8, 7), params.values[1][3]);
    try testing.expectEqual(@as(c_int, 2), params.lengths[2]);
    try testing.expectEqual(@as(c_int, 0), params.lengths[3]);
    try testing.expect(params.values[3] != null); // An empty value is not a NULL.
    try testing.expect(params.values[4] == null);
    try testing.expect(params.values[5] == null);
    try testing.expectEqual(@as(c.Oid, 20), params.types[5]);
}

/// The text of a diagnostic as default output shows it, for the golden checks below.
fn expect_designed(diag: *const Diag, code: @import("diag/codes.zig").Code) !void {
    try testing.expectEqual(code, diag.code.?);
    try testing.expect(diag.fixes.count >= 1);
    try testing.expect(diag.causes.count >= 2);
    const last = diag.last_cause().?;
    try testing.expect(std.mem.indexOf(u8, last, "libpq") == null);
    try testing.expect(std.mem.indexOf(u8, last, "SQLSTATE") == null);
    const first = diag.causes.slice()[0].slice();
    try testing.expect(std.mem.indexOf(u8, first, "reported:") != null);
}

test "connecting to a port nobody listens on is ZC-E0201 and reads well" {
    // Goal: the demo's "Postgres is down" diagnostic exists and is designed (HANDOFF C0 demo,
    // step 5). Method: connect to port 1 on the loopback, where nothing listens, and check the
    // code, the causes, the fixes and the exact text a user reads.
    var diag: Diag = undefined;
    diag.reset();
    const failed = connect(&diag, "host=127.0.0.1 port=1 dbname=zcube user=zcube", "SELECT 1");
    try testing.expectError(error.BackendFailed, failed);
    try expect_designed(&diag, .E0201);
    try testing.expectEqualStrings(
        "the Postgres server at 127.0.0.1 port 1 did not accept a connection",
        diag.last_cause().?,
    );
    try testing.expectEqualStrings(
        "start Postgres, or correct the host and port in the store settings",
        diag.fixes.slice()[0].sentence.slice(),
    );
    const check = diag.fixes.slice()[1];
    try testing.expectEqualStrings("pg_isready -h 127.0.0.1 -p 1", check.command.slice());
    try testing.expectEqual(@as(u8, constants.exit_external), diag.exit_code());
}

test "connection settings that do not parse are ZC-E0201 with libpq's words first" {
    // Goal: a typo in the settings is reported, not a crash. Method: a string with no "=".
    var diag: Diag = undefined;
    diag.reset();
    const failed = connect(&diag, "this is not conninfo", "SELECT 1");
    try testing.expectError(error.BackendFailed, failed);
    try expect_designed(&diag, .E0201);
}

test "each class fills a registered code with a fix and an operator's last cause" {
    // Goal: every class is a designed diagnostic. Method: fill each from a canned message and
    // check the code, blame (through the exit code) and that no libpq text is the last cause.
    const target: Target = .{ .host = "db", .port = "5432", .database = "zcube", .user = "zc" };
    const Case = struct { class: Class, code: @import("diag/codes.zig").Code, exit: u8 };
    const cases = [_]Case{
        .{ .class = .unreachable_server, .code = .E0201, .exit = constants.exit_external },
        .{ .class = .credentials, .code = .E0211, .exit = constants.exit_user },
        .{ .class = .database_missing, .code = .E0212, .exit = constants.exit_user },
        .{ .class = .dropped, .code = .E0213, .exit = constants.exit_external },
        .{ .class = .busy, .code = .E0208, .exit = constants.exit_environment },
        .{ .class = .damaged, .code = .E0209, .exit = constants.exit_external },
        .{ .class = .failed, .code = .E0202, .exit = constants.exit_external },
    };
    for (cases) |case| {
        var diag: Diag = undefined;
        diag.reset();
        const failed: Error!void = fill(&diag, case.class, "raw message", target, .{
            .sqlstate = "53100",
        });
        try testing.expectError(error.BackendFailed, failed);
        try testing.expectEqual(case.code, diag.code.?);
        try testing.expect(diag.fixes.count >= 1);
        try testing.expectEqual(case.exit, diag.exit_code());
        const first = diag.causes.slice()[0].slice();
        try testing.expect(std.mem.indexOf(u8, first, "raw message") != null);
    }
}

test "a commit that drops says the outcome is unknown; any other statement says nothing changed" {
    // Goal: the caller is told the truth about a write in flight. Method: fill a dropped
    // connection for a commit and for another statement.
    const target: Target = .{ .host = "db", .port = "5432", .database = "zcube", .user = "zc" };
    var diag: Diag = undefined;
    diag.reset();
    const dropped = fill(&diag, .dropped, "server closed the connection", target, .{
        .committing = true,
    });
    try testing.expectEqual(error.BackendFailed, dropped);
    try testing.expectEqual(@as(@import("diag/codes.zig").Code, .E0213), diag.code.?);
    try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "may or may not apply") != null);
    diag.reset();
    const quiet = fill(&diag, .dropped, "server closed the connection", target, .{});
    try testing.expectEqual(error.BackendFailed, quiet);
    try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "nothing was changed") != null);
}
