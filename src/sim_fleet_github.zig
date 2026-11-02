//! What the simulation fleet needs from GitHub, behind an interface so tests (and `--dry-run`)
//! use a fake: find the issue that carries a fingerprint, open an issue, comment on one. The real
//! client uses `std.http.Client` (TLS included) and a token that can file issues and nothing
//! else; the token is never printed (docs/briefs/c1-9.md).

const std = @import("std");
const assert = std.debug.assert;
const issue = @import("sim_fleet_issue.zig");

pub const Error = error{ GitHubRefused, GitHubUnreachable, OutOfMemory };

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
};

/// Records what was asked, for tests.
pub const Fake = struct {
    pub const Issue = struct { number: u32, title: []const u8, body: []const u8 };
    pub const Comment = struct { number: u32, body: []const u8 };

    gpa: std.mem.Allocator,
    issues: std.ArrayList(Issue) = .empty,
    comments: std.ArrayList(Comment) = .empty,
    finds: u32 = 0,

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
    };

    fn fake_find(ptr: *anyopaque, arena: std.mem.Allocator, fp: []const u8) Error!?u32 {
        _ = arena;
        const fake: *Fake = @ptrCast(@alignCast(ptr));
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
    };

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

/// The real thing. `token` is the text of the token file, trimmed; nothing here prints it.
pub const Http = struct {
    client: std.http.Client,
    repo: []const u8,
    token: []const u8,
    /// Where a one-line reason for a refusal goes (status and path, never headers).
    log: *std.Io.Writer,

    const api = "https://api.github.com";
    const pages_max = 5;
    const page_size = 100;

    pub fn github(http: *Http) Github {
        return .{ .ptr = http, .vtable = &http_vtable };
    }

    const http_vtable: Github.VTable = .{
        .find = http_find,
        .open = http_open,
        .comment = http_comment,
    };

    /// One request; the response body is returned. Only 200 and 201 count as success.
    fn request(
        http: *Http,
        arena: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        payload: ?[]const u8,
    ) Error![]const u8 {
        const url = try std.fmt.allocPrint(arena, "{s}/repos/{s}{s}", .{ api, http.repo, path });
        const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{http.token});
        var body: std.Io.Writer.Allocating = .init(arena);
        const extra = [_]std.http.Header{
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        };
        const result = http.client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .headers = .{
                .authorization = .{ .override = bearer },
                .user_agent = .{ .override = "zigcube-sim-fleet" },
                .content_type = if (payload != null)
                    .{ .override = "application/json" }
                else
                    .default,
            },
            .extra_headers = &extra,
            .response_writer = &body.writer,
        }) catch |err| {
            http.log.print("sim-fleet: {s} {s}: {s}\n", .{
                @tagName(method), path, @errorName(err),
            }) catch {}; // Nowhere else to report it.
            return error.GitHubUnreachable;
        };
        if (result.status != .ok and result.status != .created) {
            http.log.print("sim-fleet: {s} {s}: HTTP {d}\n", .{
                @tagName(method), path, @backingInt(result.status),
            }) catch {};
            return error.GitHubRefused;
        }
        return body.written();
    }

    fn http_find(ptr: *anyopaque, arena: std.mem.Allocator, fp: []const u8) Error!?u32 {
        const http: *Http = @ptrCast(@alignCast(ptr));
        const Row = struct { number: u32, body: ?[]const u8 = null };
        for (1..pages_max + 1) |page| {
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
        return reply.number;
    }

    fn http_comment(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        number: u32,
        body: []const u8,
    ) Error!void {
        const http: *Http = @ptrCast(@alignCast(ptr));
        const payload = try std.json.Stringify.valueAlloc(arena, .{ .body = body }, .{});
        const path = try std.fmt.allocPrint(arena, "/issues/{d}/comments", .{number});
        _ = try http.request(arena, .POST, path, payload);
    }
};

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
