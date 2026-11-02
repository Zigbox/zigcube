//! What the simulation fleet needs from GitHub, behind an interface so tests (and `--dry-run`)
//! use a fake: find the issue that carries a fingerprint, open an issue, comment on one. The real
//! client uses `std.http.Client` (TLS included) and a token that can file issues and nothing
//! else; the token is never printed (docs/briefs/c1-9.md).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const issue = @import("sim_fleet_issue.zig");

/// How a request to GitHub can fail. The first two concern one issue and the round goes on
/// without it; the rest stop every GitHub write of the round.
pub const Error = error{
    /// 404, 410 or a redirect: the issue was deleted or moved to another repository.
    GitHubGone,
    /// 403 that is not a rate limit: the issue is locked, or the token may not write it.
    GitHubForbidden,
    /// 429, or 403 with `Retry-After` or no requests left: wait `retry_after` seconds.
    GitHubRateLimited,
    /// Any other status (401: the token expired), or a reply that is not what the API returns.
    GitHubRefused,
    /// No answer: DNS, TCP, TLS, or the connection was cut.
    GitHubUnreachable,
    OutOfMemory,
};

pub const Github = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        find: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, fp: []const u8) Error!?u32,
        open: *const fn (
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            title: []const u8,
            body: []const u8,
        ) Error!u32,
        comment: *const fn (
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            number: u32,
            body: []const u8,
        ) Error!void,
        retry_after: *const fn (ptr: *anyopaque) u32,
    };

    /// The number of the issue (open or closed) whose body carries the fingerprint, if any.
    pub fn find(github: Github, arena: std.mem.Allocator, fp: []const u8) Error!?u32 {
        return github.vtable.find(github.ptr, arena, fp);
    }

    pub fn open(
        github: Github,
        arena: std.mem.Allocator,
        title: []const u8,
        body: []const u8,
    ) Error!u32 {
        return github.vtable.open(github.ptr, arena, title, body);
    }

    pub fn comment(
        github: Github,
        arena: std.mem.Allocator,
        number: u32,
        body: []const u8,
    ) Error!void {
        return github.vtable.comment(github.ptr, arena, number, body);
    }

    /// After `error.GitHubRateLimited`, the seconds GitHub asked to wait; 0 if it did not say.
    pub fn retry_after(github: Github) u32 {
        return github.vtable.retry_after(github.ptr);
    }
};

/// Records what was asked, for tests.
pub const Fake = struct {
    pub const Issue = struct { number: u32, title: []const u8, body: []const u8 };
    pub const Comment = struct { number: u32, body: []const u8 };

    gpa: std.mem.Allocator,
    issues: std.ArrayList(Issue) = .empty,
    comments: std.ArrayList(Comment) = .empty,
    finds: u32 = 0,
    /// Every request, answered or not.
    requests: u32 = 0,
    /// A comment on this issue is answered 404 (deleted or transferred).
    gone: ?u32 = null,
    /// A comment on this issue is answered 403 (locked).
    locked: ?u32 = null,
    /// Once this many requests were answered, every later one is rate limited.
    rate_limit_after: ?u32 = null,
    retry_after_seconds: u32 = 0,

    pub fn deinit(fake: *Fake) void {
        for (fake.issues.items) |item| {
            fake.gpa.free(item.title);
            fake.gpa.free(item.body);
        }
        for (fake.comments.items) |item| fake.gpa.free(item.body);
        fake.issues.deinit(fake.gpa);
        fake.comments.deinit(fake.gpa);
    }

    pub fn github(fake: *Fake) Github {
        return .{ .ptr = fake, .vtable = &fake_vtable };
    }

    const fake_vtable: Github.VTable = .{
        .find = fake_find,
        .open = fake_open,
        .comment = fake_comment,
        .retry_after = fake_retry_after,
    };

    /// Counts the request and refuses it if the rate limit is reached.
    fn admit(fake: *Fake) Error!void {
        defer fake.requests += 1;
        const allowed = fake.rate_limit_after orelse return;
        if (fake.requests >= allowed) return error.GitHubRateLimited;
    }

    fn fake_retry_after(ptr: *anyopaque) u32 {
        const fake: *Fake = @ptrCast(@alignCast(ptr));
        return fake.retry_after_seconds;
    }

    fn fake_find(ptr: *anyopaque, arena: std.mem.Allocator, fp: []const u8) Error!?u32 {
        _ = arena;
        const fake: *Fake = @ptrCast(@alignCast(ptr));
        try fake.admit();
        fake.finds += 1;
        for (fake.issues.items) |item| {
            const marker = issue.marker_of(item.body) orelse continue;
            if (std.mem.eql(u8, marker, fp)) return item.number;
        }
        return null;
    }

    fn fake_open(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        title: []const u8,
        body: []const u8,
    ) Error!u32 {
        _ = arena;
        const fake: *Fake = @ptrCast(@alignCast(ptr));
        try fake.admit();
        const title_copy = try fake.gpa.dupe(u8, title);
        errdefer fake.gpa.free(title_copy);
        const body_copy = try fake.gpa.dupe(u8, body);
        errdefer fake.gpa.free(body_copy);
        const number: u32 = @intCast(fake.issues.items.len + 1);
        try fake.issues.append(fake.gpa, .{
            .number = number,
            .title = title_copy,
            .body = body_copy,
        });
        return number;
    }

    fn fake_comment(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        number: u32,
        body: []const u8,
    ) Error!void {
        _ = arena;
        const fake: *Fake = @ptrCast(@alignCast(ptr));
        try fake.admit();
        if (fake.gone == number) return error.GitHubGone;
        if (fake.locked == number) return error.GitHubForbidden;
        const body_copy = try fake.gpa.dupe(u8, body);
        errdefer fake.gpa.free(body_copy);
        try fake.comments.append(fake.gpa, .{ .number = number, .body = body_copy });
    }
};

/// `--dry-run`: says what it would do and does nothing. It finds nothing (it never asks GitHub),
/// and numbers its issues 0, which the state file records as "filed, in a dry run".
pub const Printer = struct {
    out: *std.Io.Writer,

    pub fn github(printer: *Printer) Github {
        return .{ .ptr = printer, .vtable = &printer_vtable };
    }

    const printer_vtable: Github.VTable = .{
        .find = printer_find,
        .open = printer_open,
        .comment = printer_comment,
        .retry_after = printer_retry_after,
    };

    fn printer_retry_after(ptr: *anyopaque) u32 {
        _ = ptr;
        return 0;
    }

    fn printer_find(ptr: *anyopaque, arena: std.mem.Allocator, fp: []const u8) Error!?u32 {
        _ = .{ ptr, arena, fp };
        return null;
    }

    fn printer_open(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        title: []const u8,
        body: []const u8,
    ) Error!u32 {
        _ = arena;
        const printer: *Printer = @ptrCast(@alignCast(ptr));
        printer.out.print("would file issue: {s}\n{s}\n---\n", .{ title, body }) catch
            return error.GitHubUnreachable;
        return 0;
    }

    fn printer_comment(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        number: u32,
        body: []const u8,
    ) Error!void {
        _ = arena;
        const printer: *Printer = @ptrCast(@alignCast(ptr));
        printer.out.print("would comment on issue #{d}:\n{s}\n---\n", .{ number, body }) catch
            return error.GitHubUnreachable;
    }
};

/// What a reply's headers say about the rate limit.
pub const RateHeaders = struct {
    /// `Retry-After` in seconds, or the wait to `x-ratelimit-reset` when none are left.
    wait_seconds: ?u32 = null,
    /// `Retry-After` was sent, or `x-ratelimit-remaining` is 0.
    limited: bool = false,
};

/// The outcome of a reply's status: null for success (200, 201), else the error it means.
pub fn classify(status: u16, rate: RateHeaders) ?Error {
    assert(status >= 100);
    assert(status < 600);
    if (status == 200) return null;
    if (status == 201) return null;
    if (status == 429) return error.GitHubRateLimited;
    if (status == 403) {
        if (rate.limited) return error.GitHubRateLimited;
        return error.GitHubForbidden;
    }
    if (status == 404) return error.GitHubGone;
    if (status == 410) return error.GitHubGone;
    if (status >= 300) {
        if (status < 400) return error.GitHubGone;
    }
    return error.GitHubRefused;
}

/// Reads the rate-limit headers of a reply; `now_seconds` turns `x-ratelimit-reset` into a wait.
pub fn rate_headers(headers: *std.http.HeaderIterator, now_seconds: i64) RateHeaders {
    var rate: RateHeaders = .{};
    var reset: ?i64 = null;
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            rate.limited = true;
            // The HTTP-date form is not parsed: the default hold applies.
            rate.wait_seconds = std.fmt.parseInt(u32, header.value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-remaining")) {
            if (std.mem.eql(u8, header.value, "0")) rate.limited = true;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-reset")) {
            reset = std.fmt.parseInt(i64, header.value, 10) catch null;
        }
    }
    if (rate.wait_seconds == null and rate.limited) {
        if (reset) |at| {
            if (at > now_seconds) {
                const wait = @min(at - now_seconds, constants.fleet_hold_seconds_max);
                rate.wait_seconds = @intCast(wait);
            }
        }
    }
    return rate;
}

/// The real thing. `token` is the text of the token file, trimmed; nothing here prints it. It is
/// sent as a privileged header and no redirect is followed: the pinned `std.http.Client` keeps
/// `headers.authorization` across a redirect to another host and drops only privileged headers
/// (lib/std/http/Client.zig, `Request.redirect`), and GitHub answers a moved issue with a
/// redirect, which `classify` reads as gone.
pub const Http = struct {
    client: std.http.Client,
    repo: []const u8,
    token: []const u8,
    /// Where a one-line reason for a refusal goes (status and path, never headers).
    log: *std.Io.Writer,
    /// From the last rate-limited reply.
    wait_seconds: u32 = 0,

    const api = "https://api.github.com";

    pub fn github(http: *Http) Github {
        return .{ .ptr = http, .vtable = &http_vtable };
    }

    const http_vtable: Github.VTable = .{
        .find = http_find,
        .open = http_open,
        .comment = http_comment,
        .retry_after = http_retry_after,
    };

    fn http_retry_after(ptr: *anyopaque) u32 {
        const http: *Http = @ptrCast(@alignCast(ptr));
        return http.wait_seconds;
    }

    /// One request; the response body is returned, read up to the response limit. No timeout of
    /// its own: `run.sh` runs `sim_fleet` under `timeout`.
    fn request(
        http: *Http,
        arena: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        payload: ?[]const u8,
    ) Error![]const u8 {
        assert(path.len > 0);
        assert(path[0] == '/');
        const url = try std.fmt.allocPrint(arena, "{s}/repos/{s}{s}", .{ api, http.repo, path });
        const uri = std.Uri.parse(url) catch return error.GitHubRefused;
        const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{http.token});
        const extra = [_]std.http.Header{
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        };
        const privileged = [_]std.http.Header{.{ .name = "Authorization", .value = bearer }};
        var req = http.client.request(method, uri, .{
            .redirect_behavior = .not_allowed,
            .headers = .{
                .authorization = .omit,
                .user_agent = .{ .override = "zigcube-sim-fleet" },
                .accept_encoding = .omit,
                .content_type = if (payload != null)
                    .{ .override = "application/json" }
                else
                    .omit,
            },
            .extra_headers = &extra,
            .privileged_headers = &privileged,
        }) catch |err| return http.unreachable_error(method, path, @errorName(err));
        defer req.deinit();
        send(&req, payload) catch |err|
            return http.unreachable_error(method, path, @errorName(err));
        var response = req.receiveHead(&.{}) catch |err| switch (err) {
            error.TooManyHttpRedirects => return http.refused(method, path, 301, error.GitHubGone),
            else => return http.unreachable_error(method, path, @errorName(err)),
        };
        const status = @backingInt(response.head.status);
        var headers = response.head.iterateHeaders();
        const now = std.Io.Clock.real.now(http.client.io).toSeconds();
        const rate = rate_headers(&headers, now);
        const identity = response.head.content_encoding == .identity;
        var transfer: [64]u8 = undefined;
        const body = response.reader(&transfer).allocRemaining(
            arena,
            .limited(constants.fleet_response_bytes_max),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return http.refused(method, path, status, error.GitHubRefused),
            error.ReadFailed => return http.unreachable_error(method, path, "ReadFailed"),
        };
        if (!identity) return http.refused(method, path, status, error.GitHubRefused);
        if (classify(status, rate)) |failure| {
            if (failure == error.GitHubRateLimited) http.wait_seconds = rate.wait_seconds orelse 0;
            return http.refused(method, path, status, failure);
        }
        return body;
    }

    fn send(req: *std.http.Client.Request, payload: ?[]const u8) !void {
        const bytes = payload orelse return req.sendBodiless();
        req.transfer_encoding = .{ .content_length = bytes.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(bytes);
        try body.end();
        try req.connection.?.flush();
    }

    fn unreachable_error(
        http: *Http,
        method: std.http.Method,
        path: []const u8,
        why: []const u8,
    ) Error {
        http.log.print("sim-fleet: {s} {s}: no answer from GitHub ({s})\n", .{
            @tagName(method), path, why,
        }) catch {}; // Nowhere else to report it.
        return error.GitHubUnreachable;
    }

    fn refused(
        http: *Http,
        method: std.http.Method,
        path: []const u8,
        status: u16,
        failure: Error,
    ) Error {
        const meaning: []const u8 = switch (failure) {
            error.GitHubGone => "the issue was deleted or moved; it is filed again",
            error.GitHubForbidden => "forbidden; the issue may be locked; skipped",
            error.GitHubRateLimited => "rate limited; GitHub writes wait",
            else => if (status == 401) "the token is wrong or expired" else "refused",
        };
        http.log.print("sim-fleet: {s} {s}: HTTP {d}: {s}\n", .{
            @tagName(method), path, status, meaning,
        }) catch {}; // Nowhere else to report it.
        return failure;
    }

    fn http_find(ptr: *anyopaque, arena: std.mem.Allocator, fp: []const u8) Error!?u32 {
        const http: *Http = @ptrCast(@alignCast(ptr));
        const Row = struct { number: u32, body: ?[]const u8 = null };
        const page_size = constants.fleet_find_page_size;
        for (1..constants.fleet_find_pages_max + 1) |page| {
            const path = try std.fmt.allocPrint(
                arena,
                "/issues?labels={s}&state=all&per_page={d}&page={d}",
                .{ issue.label, page_size, page },
            );
            const text = try http.request(arena, .GET, path, null);
            const rows = std.json.parseFromSliceLeaky([]const Row, arena, text, .{
                .ignore_unknown_fields = true,
            }) catch return error.GitHubRefused;
            for (rows) |row| {
                const marker = issue.marker_of(row.body orelse continue) orelse continue;
                if (std.mem.eql(u8, marker, fp)) return row.number;
            }
            if (rows.len < page_size) break;
        }
        return null;
    }

    fn http_open(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        title: []const u8,
        body: []const u8,
    ) Error!u32 {
        const http: *Http = @ptrCast(@alignCast(ptr));
        const payload = try std.json.Stringify.valueAlloc(arena, .{
            .title = title,
            .body = body,
            .labels = [_][]const u8{issue.label},
        }, .{});
        const text = try http.request(arena, .POST, "/issues", payload);
        const reply = std.json.parseFromSliceLeaky(struct { number: u32 }, arena, text, .{
            .ignore_unknown_fields = true,
        }) catch return error.GitHubRefused;
        if (reply.number == 0) return error.GitHubRefused;
        return reply.number;
    }

    fn http_comment(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        number: u32,
        body: []const u8,
    ) Error!void {
        const http: *Http = @ptrCast(@alignCast(ptr));
        assert(number > 0);
        const payload = try std.json.Stringify.valueAlloc(arena, .{ .body = body }, .{});
        const path = try std.fmt.allocPrint(arena, "/issues/{d}/comments", .{number});
        _ = try http.request(arena, .POST, path, payload);
    }
};

test "a status and its rate-limit headers decide what a refusal means" {
    // Goal: H1/H2, only a rate limit stops the round; a locked or gone issue is skipped or
    // filed again. Method: every class of status, and 403 with and without the rate headers.
    try std.testing.expectEqual(@as(?Error, null), classify(200, .{}));
    try std.testing.expectEqual(@as(?Error, null), classify(201, .{}));
    try std.testing.expectEqual(@as(?Error, error.GitHubRateLimited), classify(429, .{}));
    const limited: RateHeaders = .{ .limited = true, .wait_seconds = 60 };
    try std.testing.expectEqual(@as(?Error, error.GitHubRateLimited), classify(403, limited));
    try std.testing.expectEqual(@as(?Error, error.GitHubForbidden), classify(403, .{}));
    try std.testing.expectEqual(@as(?Error, error.GitHubGone), classify(404, .{}));
    try std.testing.expectEqual(@as(?Error, error.GitHubGone), classify(410, .{}));
    try std.testing.expectEqual(@as(?Error, error.GitHubGone), classify(301, .{}));
    try std.testing.expectEqual(@as(?Error, error.GitHubRefused), classify(401, .{}));
    try std.testing.expectEqual(@as(?Error, error.GitHubRefused), classify(422, .{}));
    try std.testing.expectEqual(@as(?Error, error.GitHubRefused), classify(502, .{}));
}

test "rate-limit headers: Retry-After, or the wait to the reset when none are left" {
    // Goal: H1, Retry-After is honoured. Method: parse real header blocks with the std iterator.
    const retry = "HTTP/1.1 403 Forbidden\r\nRetry-After: 120\r\nX-RateLimit-Remaining: 9\r\n\r\n";
    var headers = std.http.HeaderIterator.init(retry);
    const a = rate_headers(&headers, 1000);
    try std.testing.expect(a.limited);
    try std.testing.expectEqual(@as(?u32, 120), a.wait_seconds);
    const reset = "HTTP/1.1 403 Forbidden\r\nx-ratelimit-remaining: 0\r\n" ++
        "x-ratelimit-reset: 1600\r\n\r\n";
    headers = std.http.HeaderIterator.init(reset);
    const b = rate_headers(&headers, 1000);
    try std.testing.expect(b.limited);
    try std.testing.expectEqual(@as(?u32, 600), b.wait_seconds);
    const plain = "HTTP/1.1 403 Forbidden\r\nx-ratelimit-remaining: 4999\r\n\r\n";
    headers = std.http.HeaderIterator.init(plain);
    const c = rate_headers(&headers, 1000);
    try std.testing.expect(!c.limited);
    try std.testing.expectEqual(@as(?u32, null), c.wait_seconds);
}

test "the fake finds an issue by the marker in its body" {
    var fake: Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const github = fake.github();
    const body = "body\n<!-- sim-fleet fingerprint: 0123456789abcdef -->\n";
    const number = try github.open(arena, "t", body);
    try std.testing.expectEqual(@as(u32, 1), number);
    try std.testing.expectEqual(@as(?u32, 1), try github.find(arena, "0123456789abcdef"));
    try std.testing.expectEqual(@as(?u32, null), try github.find(arena, "fedcba9876543210"));
    try github.comment(arena, 1, "again");
    try std.testing.expectEqual(@as(usize, 1), fake.comments.items.len);
}
