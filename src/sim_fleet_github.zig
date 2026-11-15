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
    /// Any other status (401: the token expired or was revoked), or a reply that is not what the
    /// API returns.
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

/// What `refused` logs for a 401, in the fleet's journal (owner, 2026-11-15).
pub const token_refused = "token refused (expired or revoked): replace /etc/sim-fleet/token";

/// GitHub's header on a reply to a fine-grained token that expires (or a classic one with an
/// expiry): when it does.
pub const token_expiry_header = "github-authentication-token-expiration";

/// Unix seconds of a `github-authentication-token-expiration` value: GitHub does not document
/// its form; it is `2026-12-01 09:30:00 UTC` (or `-0800` in place of `UTC`). Null for anything
/// else.
pub fn parse_expiry(value: []const u8) ?i64 {
    var words = std.mem.tokenizeScalar(u8, std.mem.trim(u8, value, " \t"), ' ');
    const date = words.next() orelse return null;
    const time = words.next() orelse return null;
    const zone = words.next() orelse "UTC";
    if (words.next() != null) return null;
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return null;
    if (time.len != 8 or time[2] != ':' or time[5] != ':') return null;
    const year = std.fmt.parseInt(u16, date[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, date[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, date[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, time[0..2], 10) catch return null;
    const minute = std.fmt.parseInt(u8, time[3..5], 10) catch return null;
    const second = std.fmt.parseInt(u8, time[6..8], 10) catch return null;
    if (year < 1970 or month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    const offset = zone_offset(zone) orelse return null;
    const days = days_from_civil(year, month, day);
    const at = days * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second - offset;
    if (at < 0) return null;
    return at;
}

/// Seconds east of UTC of `UTC`, `Z` or `+hhmm`/`-hhmm`; null for anything else.
fn zone_offset(zone: []const u8) ?i64 {
    if (std.mem.eql(u8, zone, "UTC") or std.mem.eql(u8, zone, "Z")) return 0;
    if (zone.len != 5) return null;
    const sign: i64 = switch (zone[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    for (zone[1..]) |byte| if (!std.ascii.isDigit(byte)) return null;
    const hours = std.fmt.parseInt(i64, zone[1..3], 10) catch return null;
    const minutes = std.fmt.parseInt(i64, zone[3..5], 10) catch return null;
    if (hours > 14 or minutes > 59) return null;
    return sign * (hours * 3600 + minutes * 60);
}

/// Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant's `days_from_civil`).
fn days_from_civil(year: u16, month: u8, day: u8) i64 {
    assert(month >= 1);
    assert(month <= 12);
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const m: i64 = month;
    const shifted: i64 = if (m > 2) m - 3 else m + 9;
    const day_of_year = @divFloor(153 * shifted + 2, 5) + @as(i64, day) - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

/// Sends the heartbeat: one GET of `url`, no redirect followed, nothing sent but the request
/// line and the host. `url` is a secret (it lets anyone report the fleet alive), so nothing here
/// prints it: the log gets "heartbeat sent" or "heartbeat failed: ...". Plain http is refused
/// except to the loopback address (tests). True if it was sent and answered 2xx.
pub fn send_heartbeat(
    client: *std.http.Client,
    url: []const u8,
    log: *std.Io.Writer,
) bool {
    const uri = std.Uri.parse(url) catch {
        log.writeAll("sim-fleet: heartbeat failed: the heartbeat file holds no URL\n") catch {};
        return false;
    };
    if (!heartbeat_scheme_allowed(uri)) {
        log.writeAll("sim-fleet: heartbeat failed: the URL is not https\n") catch {};
        return false;
    }
    var req = client.request(.GET, uri, .{
        // Seen, never followed: a redirect is a failure.
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .authorization = .omit,
            .user_agent = .{ .override = "zigcube-sim-fleet" },
            .accept_encoding = .omit,
        },
    }) catch |err| return heartbeat_unanswered(log, err);
    defer req.deinit();
    req.sendBodiless() catch |err| return heartbeat_unanswered(log, err);
    var response = req.receiveHead(&.{}) catch |err| return heartbeat_unanswered(log, err);
    const status = @backingInt(response.head.status);
    var transfer: [64]u8 = undefined;
    // The body says nothing the status does not; it is read so the connection ends cleanly.
    const limit: std.Io.Limit = .limited(constants.fleet_response_bytes_max);
    _ = response.reader(&transfer).discard(limit) catch {}; // Its end, or a cut: either will do.
    if (status < 200 or status >= 300) {
        log.print("sim-fleet: heartbeat failed: status {d}\n", .{status}) catch {};
        return false;
    }
    log.writeAll("sim-fleet: heartbeat sent\n") catch {};
    return true;
}

fn heartbeat_scheme_allowed(uri: std.Uri) bool {
    if (std.mem.eql(u8, uri.scheme, "https")) return true;
    if (!std.mem.eql(u8, uri.scheme, "http")) return false;
    const host = uri.host orelse return false;
    var buffer: [255]u8 = undefined; // A DNS name's most.
    const name = host.toRaw(&buffer) catch return false;
    return std.mem.eql(u8, name, "127.0.0.1");
}

fn heartbeat_unanswered(log: *std.Io.Writer, err: anyerror) bool {
    // The error's name only: std's errors carry no part of the URL.
    log.print("sim-fleet: heartbeat failed: no answer ({s})\n", .{@errorName(err)}) catch {};
    return false;
}

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
    /// When the token expires, from the last reply that said (`token_expiry_header`).
    token_expires: ?i64 = null,
    /// A reply sent the expiry header in a form `parse_expiry` does not read.
    token_expiry_unread: bool = false,

    /// The REST root; tests point it at a loopback server.
    api: []const u8 = "https://api.github.com",

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
        // Empty: the repository itself (`check_token`).
        if (path.len > 0) assert(path[0] == '/');
        const url = try std.fmt.allocPrint(arena, "{s}/repos/{s}{s}", .{
            http.api, http.repo, path,
        });
        const uri = std.Uri.parse(url) catch return error.GitHubRefused;
        const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{http.token});
        // Not `privileged_headers`: the pinned std keeps those for redirects and never writes
        // them into the request head, so GitHub saw no token and answered 401. Redirects are
        // `.not_allowed`, so the token cannot follow one to another host.
        const extra = [_]std.http.Header{
            .{ .name = "Authorization", .value = bearer },
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        };
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
        var expiry_headers = response.head.iterateHeaders();
        http.read_expiry(&expiry_headers);
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
            @tagName(method), shown(path), why,
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
            else => if (status == 401) token_refused else "refused",
        };
        http.log.print("sim-fleet: {s} {s}: HTTP {d}: {s}\n", .{
            @tagName(method), shown(path), status, meaning,
        }) catch {}; // Nowhere else to report it.
        return failure;
    }

    /// The path a log line names: the token check asks for the repository itself.
    fn shown(path: []const u8) []const u8 {
        return if (path.len == 0) "(the repository: token check)" else path;
    }

    fn read_expiry(http: *Http, headers: *std.http.HeaderIterator) void {
        while (headers.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, token_expiry_header)) continue;
            if (parse_expiry(header.value)) |at| {
                http.token_expires = at;
            } else {
                http.token_expiry_unread = true;
            }
        }
    }

    /// Asks GitHub for the repository: does the token still work, and when does it expire. One
    /// request a round (`sim_fleet heartbeat`), so a round with nothing to file still finds out.
    pub fn check_token(http: *Http, arena: std.mem.Allocator) Error!void {
        _ = try http.request(arena, .GET, "", null);
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

const Recorded = struct {
    heads: [3][1024]u8 = undefined,
    lens: [3]u32 = .{ 0, 0, 0 },
    count: u32 = 0,

    fn head(recorded: *const Recorded, index: u32) []const u8 {
        return recorded.heads[index][0..recorded.lens[index]];
    }
};

/// Serves three requests (over however many connections) and records each request head.
fn serve_three(io: std.Io, listener: *std.Io.net.Server, recorded: *Recorded) void {
    const replies = [3][]const u8{ "[]", "{\"number\":7}", "{}" };
    while (recorded.count < 3) {
        const stream = listener.accept(io) catch return;
        defer stream.close(io);
        var in_buffer: [2048]u8 = undefined;
        var out_buffer: [512]u8 = undefined;
        var reader = stream.reader(io, &in_buffer);
        var writer = stream.writer(io, &out_buffer);
        while (recorded.count < 3) {
            var length: usize = 0;
            var content_length: usize = 0;
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch break;
                const slot = &recorded.heads[recorded.count];
                if (length + line.len > slot.len) return;
                @memcpy(slot[length..][0..line.len], line);
                length += line.len;
                const lower = "content-length: ";
                if (line.len > lower.len and std.ascii.startsWithIgnoreCase(line, lower)) {
                    content_length = std.fmt.parseInt(
                        usize,
                        std.mem.trim(u8, line[lower.len..], " \r\n"),
                        10,
                    ) catch return;
                }
                if (line.len == 2) break; // The empty line ends the head.
            } else unreachable;
            if (length == 0) break; // Connection closed between requests.
            reader.interface.discardAll(content_length) catch return;
            recorded.lens[recorded.count] = @intCast(length);
            const body = replies[recorded.count];
            recorded.count += 1;
            writer.interface.print(
                "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\n\r\n{s}",
                .{ body.len, body },
            ) catch return;
            writer.interface.flush() catch return;
        }
    }
}

test "every request carries the Authorization header, on a reused connection too" {
    // Goal: GitHub answered 401 to a valid token in production (fleet, 2026-11-03) because the
    // pinned std never writes `privileged_headers` into the request head. Method: a loopback
    // server records the head of find, open and comment, which share one client.
    const io = std.testing.io;
    const any = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try any.listen(io, .{});
    defer listener.deinit(io);
    var recorded: Recorded = .{};
    const thread = try std.Thread.spawn(.{}, serve_three, .{ io, &listener, &recorded });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sink: [256]u8 = undefined;
    var log: std.Io.Writer = .fixed(&sink);
    var url_buffer: [64]u8 = undefined;
    const api = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}", .{
        listener.socket.address.getPort(),
    });
    var http: Http = .{
        .client = .{ .allocator = std.testing.allocator, .io = io },
        .repo = "o/r",
        .token = "tok-123",
        .log = &log,
        .api = api,
    };
    defer http.client.deinit();
    const github = http.github();
    try std.testing.expectEqual(@as(?u32, null), try github.find(arena, "fp"));
    try std.testing.expectEqual(@as(u32, 7), try github.open(arena, "t", "b"));
    try github.comment(arena, 7, "c");
    thread.join();
    try std.testing.expectEqual(@as(u32, 3), recorded.count);
    for (0..3) |index| {
        const head = recorded.head(@intCast(index));
        try std.testing.expect(std.ascii.findIgnoreCase(
            head,
            "\r\nauthorization: Bearer tok-123\r\n",
        ) != null);
    }
}

test "the token's expiry header is read in either form, and nothing else is" {
    // 2026-12-01 09:30:00 UTC.
    const at: i64 = 1_796_117_400;
    try std.testing.expectEqual(@as(?i64, at), parse_expiry("2026-12-01 09:30:00 UTC"));
    try std.testing.expectEqual(@as(?i64, at), parse_expiry("2026-12-01 09:30:00"));
    try std.testing.expectEqual(@as(?i64, at), parse_expiry(" 2026-12-01 01:30:00 -0800"));
    try std.testing.expectEqual(@as(?i64, at), parse_expiry("2026-12-01 10:30:00 +0100"));
    try std.testing.expectEqual(@as(?i64, 951_782_400), parse_expiry("2000-02-29 00:00:00 UTC"));
    try std.testing.expectEqual(@as(?i64, 0), parse_expiry("1970-01-01 00:00:00 UTC"));
    try std.testing.expectEqual(@as(?i64, null), parse_expiry(""));
    try std.testing.expectEqual(@as(?i64, null), parse_expiry("2026-12-01"));
    try std.testing.expectEqual(@as(?i64, null), parse_expiry("2026-13-01 00:00:00 UTC"));
    try std.testing.expectEqual(@as(?i64, null), parse_expiry("2026-12-01 24:00:00 UTC"));
    try std.testing.expectEqual(@as(?i64, null), parse_expiry("2026-12-01 09:30:00 PST"));
    try std.testing.expectEqual(@as(?i64, null), parse_expiry("2026-12-01 09:30:00 +08:00"));
    try std.testing.expectEqual(@as(?i64, null), parse_expiry("2026-12-01 09:30:00 UTC x"));
    try std.testing.expectEqual(@as(?i64, null), parse_expiry("Tue, 01 Dec 2026 09:30:00 GMT"));
}

/// Serves one request with `reply` (a whole response) and records its head.
fn serve_one(
    io: std.Io,
    listener: *std.Io.net.Server,
    reply: []const u8,
    recorded: *Recorded,
) void {
    const stream = listener.accept(io) catch return;
    defer stream.close(io);
    var in_buffer: [2048]u8 = undefined;
    var out_buffer: [512]u8 = undefined;
    var reader = stream.reader(io, &in_buffer);
    var writer = stream.writer(io, &out_buffer);
    var length: usize = 0;
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch return;
        const slot = &recorded.heads[0];
        if (length + line.len > slot.len) return;
        @memcpy(slot[length..][0..line.len], line);
        length += line.len;
        if (line.len == 2) break; // The empty line ends the head.
    }
    recorded.lens[0] = @intCast(length);
    recorded.count = 1;
    writer.interface.writeAll(reply) catch return;
    writer.interface.flush() catch return;
}

const Served = struct {
    log_buffer: [512]u8 = undefined,
    log: std.Io.Writer = undefined,
    recorded: Recorded = .{},
    url_buffer: [96]u8 = undefined,
    url: []const u8 = "",
};

/// Runs `serve_one` with `reply` and sends the heartbeat to it; the URL carries a secret path.
fn heartbeat_against(served: *Served, reply: []const u8) !bool {
    const io = std.testing.io;
    const any = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try any.listen(io, .{});
    defer listener.deinit(io);
    served.log = .fixed(&served.log_buffer);
    served.url = try std.fmt.bufPrint(&served.url_buffer, "http://127.0.0.1:{d}/ping/s3cr3t", .{
        listener.socket.address.getPort(),
    });
    const args = .{ io, &listener, reply, &served.recorded };
    const thread = try std.Thread.spawn(.{}, serve_one, args);
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    const sent = send_heartbeat(&client, served.url, &served.log);
    thread.join();
    return sent;
}

test "the heartbeat is one GET with no credentials; its URL is never logged" {
    var served: Served = .{};
    const ok = "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nOK";
    try std.testing.expect(try heartbeat_against(&served, ok));
    try std.testing.expectEqualStrings("sim-fleet: heartbeat sent\n", served.log.buffered());
    const head = served.recorded.head(0);
    try std.testing.expect(std.mem.startsWith(u8, head, "GET /ping/s3cr3t HTTP/1.1\r\n"));
    try std.testing.expect(std.ascii.findIgnoreCase(head, "authorization") == null);
}

test "a heartbeat answered with a redirect is a failure, and the redirect is not followed" {
    // Goal: never follow a redirect (the brief), so the URL's secret and the request stay with
    // the host it names. Method: a 302 to another host; one request is made, the log says the
    // status, and neither URL is logged.
    var served: Served = .{};
    const moved = "HTTP/1.1 302 Found\r\nlocation: http://127.0.0.2:1/elsewhere\r\n" ++
        "content-length: 0\r\nconnection: close\r\n\r\n";
    try std.testing.expect(!try heartbeat_against(&served, moved));
    try std.testing.expectEqualStrings(
        "sim-fleet: heartbeat failed: status 302\n",
        served.log.buffered(),
    );
    try std.testing.expectEqual(@as(u32, 1), served.recorded.count);
    var served_error: Served = .{};
    const failed = "HTTP/1.1 500 Oops\r\ncontent-length: 0\r\nconnection: close\r\n\r\n";
    try std.testing.expect(!try heartbeat_against(&served_error, failed));
    try std.testing.expectEqualStrings(
        "sim-fleet: heartbeat failed: status 500\n",
        served_error.log.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(u8, served_error.log.buffered(), "s3cr3t") == null);
}

test "a heartbeat URL that is not https, or not a URL, is refused unsent and unlogged" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var buffer: [256]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buffer);
    try std.testing.expect(!send_heartbeat(&client, "http://example.com/s3cr3t", &log));
    try std.testing.expect(!send_heartbeat(&client, "s3cr3t", &log));
    try std.testing.expect(!send_heartbeat(&client, "ftp://example.com/s3cr3t", &log));
    try std.testing.expectEqualStrings(
        "sim-fleet: heartbeat failed: the URL is not https\n" ++
            "sim-fleet: heartbeat failed: the heartbeat file holds no URL\n" ++
            "sim-fleet: heartbeat failed: the URL is not https\n",
        log.buffered(),
    );
}

/// Runs `serve_one` with `reply` and checks the token against it.
fn check_against(served: *Served, http: *Http, reply: []const u8) Error!void {
    const io = std.testing.io;
    const any = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable; // A literal.
    var listener = any.listen(io, .{}) catch return error.GitHubUnreachable;
    defer listener.deinit(io);
    served.log = .fixed(&served.log_buffer);
    served.url = std.fmt.bufPrint(&served.url_buffer, "http://127.0.0.1:{d}", .{
        listener.socket.address.getPort(),
    }) catch unreachable; // 96 bytes hold the loopback address and a port.
    http.api = served.url;
    http.log = &served.log;
    const args = .{ io, &listener, reply, &served.recorded };
    const thread = std.Thread.spawn(.{}, serve_one, args) catch return error.GitHubUnreachable;
    defer thread.join();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    return http.check_token(arena_state.allocator());
}

test "the token check reads the expiry header; a 401 says to replace the token" {
    var served: Served = .{};
    var sink: [8]u8 = undefined;
    var unused: std.Io.Writer = .fixed(&sink);
    var http: Http = .{
        .client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
        .repo = "o/r",
        .token = "tok-123",
        .log = &unused,
    };
    defer http.client.deinit();
    const ok = "HTTP/1.1 200 OK\r\n" ++
        "GitHub-Authentication-Token-Expiration: 2026-12-01 09:30:00 UTC\r\n" ++
        "content-length: 2\r\nconnection: close\r\n\r\n{}";
    try check_against(&served, &http, ok);
    try std.testing.expectEqual(@as(?i64, 1_796_117_400), http.token_expires);
    try std.testing.expect(!http.token_expiry_unread);
    const head = served.recorded.head(0);
    try std.testing.expect(std.mem.startsWith(u8, head, "GET /repos/o/r HTTP/1.1\r\n"));
    var refused: Served = .{};
    const denied = "HTTP/1.1 401 Unauthorized\r\ncontent-length: 2\r\n" ++
        "connection: close\r\n\r\n{}";
    try std.testing.expectError(error.GitHubRefused, check_against(&refused, &http, denied));
    try std.testing.expectEqualStrings(
        "sim-fleet: GET (the repository: token check): HTTP 401: " ++ token_refused ++ "\n",
        refused.log.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(u8, refused.log.buffered(), "tok-123") == null);
}
