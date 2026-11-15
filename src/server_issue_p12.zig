//! `zcube-server ca issue-client NAME --scope S --p12 FILE` (B7 slice 6,
//! docs/decisions/2026-11-14-b7-slice6-console-over-tls.md): a browser's client certificate. A
//! fresh P-256 key and a certificate from the store's browser CA, with the same name, scope,
//! revoked file and lifetime as `server_issue.zig`'s, in one PKCS#12 file (`pkcs12.zig`), mode
//! 0600, never overwritten. The password is read from `--password-file` (mode 0600) or from
//! stdin when stdin is not a terminal (a terminal would echo it); never from argv. One trailing
//! newline is not part of it, and an empty one is refused. The browser CA is never made here.
//!
//! Shell code.

const std = @import("std");
const assert = std.debug.assert;
const config_mod = @import("server_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const files = @import("peer_files.zig");
const issue_mod = @import("server_issue.zig");
const p256 = @import("x509_p256.zig");
const peer_ca = @import("peer_ca.zig");
const pkcs12 = @import("pkcs12.zig");
const browser_ca = @import("server_browser_ca.zig");
const secure_random = @import("secure_random.zig");
const server_ca = @import("server_ca.zig");
const RealClock = @import("server_store.zig").RealClock;

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Error = issue_mod.Error;

/// A password is read whole into a buffer this long; a longer one is refused.
const password_bytes_max = constants.peer_file_bytes_max;

/// Signs and writes the PKCS#12 file. On failure `diag` says why.
pub fn issue(
    gpa: Allocator,
    io: std.Io,
    request: *const config_mod.Issue,
    diag: *Diag,
) Error!issue_mod.Issued {
    assert(diag.code == null);
    assert(request.subject == .client);
    const path = request.p12.?;
    // The password first: a refusal there costs nothing and leaves nothing behind.
    const password_buffer = try gpa.alloc(u8, password_bytes_max + 1);
    defer {
        std.crypto.secureZero(u8, password_buffer);
        gpa.free(password_buffer);
    }
    const password = try read_password(io, request.password_file, password_buffer, diag);

    var real: RealClock = .{ .io = io };
    var ca: peer_ca.Ca = undefined;
    try issue_mod.open_ca(&ca, gpa, io, &request.config, real.clock(), diag);
    const browser = try open_browser(gpa, io, &ca, &request.config, diag);

    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    const key = try browser_ca.make_key(io, &seed, diag);
    var certificate: p256.Der = .{};
    browser_ca.issue_client(
        &certificate,
        &ca,
        browser,
        request.name,
        request.subject.client,
        key,
        issue_mod.ttl_ms,
    ) catch |err| return issue_mod.refused(diag, request, err);
    const parsed = p256.verify(certificate.slice(), p256.point_of(browser), ca.wall.now_ms(), .{
        .kind = .client,
        .name = null,
    }) catch unreachable; // The CA just issued it, valid from now for seven days.

    var input: pkcs12.Input = .{
        .certificate = certificate.slice(),
        .key = key,
        .password = password,
        .mac_salt = undefined,
        .key_salt = undefined,
        .iv = undefined,
    };
    var randomness: [48]u8 = undefined;
    secure_random.fill(io, &randomness, diag, "the PKCS#12 salts") catch |err| return switch (err) {
        error.Unavailable => error.Failed,
        error.Canceled => error.Canceled,
    };
    input.mac_salt = randomness[0..16].*;
    input.key_salt = randomness[16..32].*;
    input.iv = randomness[32..48].*;
    var out: [pkcs12.bytes_max]u8 = undefined;
    defer std.crypto.secureZero(u8, &out);
    const bytes = pkcs12.write(&out, gpa, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadPassword => return bad_password(diag, "it is not UTF-8"),
        error.NoSpace, error.Malformed => unreachable, // Sizes fixed by the profile.
    };
    try write_file(io, path, bytes, diag);
    return .{ .not_after_ms = parsed.not_after_ms };
}

/// The browser CA of the store, which the server made; refused when absent (ZC-E0806).
fn open_browser(
    gpa: Allocator,
    io: std.Io,
    ca: *const peer_ca.Ca,
    config: *const config_mod.Config,
    diag: *Diag,
) Error!browser_ca.KeyPair {
    // `open_ca` succeeded, so the store has a state directory.
    const directory = @import("server.zig").Server.state_path(config.*, diag).?;
    var name_buffer: [server_ca.key_name_bytes_max]u8 = undefined;
    const key_name = try issue_mod.key_name_of(gpa, io, config.store, &name_buffer, diag);
    const quiet = false; // `ca issue-client` says on stderr that the root was made again.
    const opened = browser_ca.open(io, ca, directory, key_name, .refuse, quiet, diag);
    return opened catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.Failed => error.Failed,
    };
}

fn read_password(
    io: std.Io,
    file: ?[]const u8,
    buffer: []u8,
    diag: *Diag,
) Error![]const u8 {
    assert(buffer.len == password_bytes_max + 1);
    const text = if (file) |path| text: {
        const cwd = std.Io.Dir.cwd();
        const found = try files.read_bounded(io, cwd, ".", path, .secret, buffer, diag);
        break :text switch (found) {
            .absent => return files.unusable(diag, ".", path, "read", "it does not exist"),
            .too_long => return bad_password(diag, "it is longer than 32 KiB"),
            .bytes => |bytes| bytes,
        };
    } else try read_stdin(io, buffer, diag);
    var password = text;
    if (std.mem.endsWith(u8, password, "\n")) password = password[0 .. password.len - 1];
    if (std.mem.endsWith(u8, password, "\r")) password = password[0 .. password.len - 1];
    if (password.len == 0) return bad_password(diag, "it is empty");
    if (!std.unicode.utf8ValidateSlice(password)) return bad_password(diag, "it is not UTF-8");
    return password;
}

fn read_stdin(io: std.Io, buffer: []u8, diag: *Diag) Error![]const u8 {
    const stdin = std.Io.File.stdin();
    if (stdin.isTty(io) catch false) {
        diag.raise(.E0106);
        diag.cause("ca issue-client --p12 reads its password from stdin, which is a terminal " ++
            "(it would show the password)", .{});
        diag.fix(.{ .sentence = "give --password-file F (mode 0600), or pipe the password in" });
        return error.Failed;
    }
    var reader_buffer: [1024]u8 = undefined;
    var reader = stdin.readerStreaming(io, &reader_buffer);
    defer std.crypto.secureZero(u8, &reader_buffer);
    var length: usize = 0;
    while (length < buffer.len) {
        const count = reader.interface.readSliceShort(buffer[length..]) catch {
            diag.raise(.E0106);
            diag.cause("can't read the PKCS#12 password from stdin", .{});
            diag.fix(.{ .sentence = "give --password-file F (mode 0600) instead" });
            return error.Failed;
        };
        if (count == 0) break;
        length += count;
    }
    if (length == buffer.len) return bad_password(diag, "it is longer than 32 KiB");
    return buffer[0..length];
}

fn bad_password(diag: *Diag, why: []const u8) Error {
    diag.raise(.E0106);
    diag.cause("can't use the PKCS#12 password: {s}", .{why});
    diag.fix(.{ .sentence = "give one line of UTF-8 text, in --password-file F or on stdin" });
    return error.Failed;
}

/// Writes `bytes` to `path`, mode 0600, never over an existing file.
fn write_file(io: std.Io, path: []const u8, bytes: []const u8, diag: *Diag) Error!void {
    const where = std.fs.path.dirname(path) orelse ".";
    const name = std.fs.path.basename(path);
    if (name.len == 0 or name.len + files.temp_suffix_bytes > files.temp_bytes_max) {
        const fix = "choose a file name of at most 75 bytes";
        return files.unusable_fix(diag, where, path, "write", "the name is too long", fix);
    }
    var dir = std.Io.Dir.cwd().openDir(io, where, .{}) catch |err| {
        return files.unusable(diag, where, name, "open the directory for", @errorName(err));
    };
    defer dir.close(io);
    var temp_buffer: [files.temp_bytes_max]u8 = undefined;
    const temp = try files.stage(io, dir, where, name, bytes, 0o600, &temp_buffer, diag);
    defer dir.deleteFile(io, temp) catch {}; // Gone once renamed; nothing more to do.
    dir.renamePreserve(temp, dir, name, io) catch |err| {
        if (err != error.PathAlreadyExists) {
            return files.unusable(diag, where, name, "write", @errorName(err));
        }
        const fix = "remove it first to re-issue, or choose another --p12 file";
        return files.unusable_fix(diag, where, name, "write", "it already exists", fix);
    };
    try files.sync_dir(io, dir, where, name, diag);
}

const testing = std.testing;
const Code = @import("diag/codes.zig").Code;

fn issue_test(arena: Allocator, dir: []const u8, extra: []const []const u8, diag: *Diag) !void {
    diag.reset();
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "ca", "issue-client", "web-1", "--scope", "jobs" });
    try args.appendSlice(arena, extra);
    try args.appendSlice(arena, &.{ "--store", "postgres:host=x", "--state-dir", dir });
    const loaded = try config_mod.load(arena, testing.io, args.items, diag);
    _ = try issue(testing.allocator, testing.io, &loaded.ca_issue, diag);
}

test "ca issue-client --p12 writes a 0600 file once, and refuses a missing CA or bad password" {
    // Goal: the command's file handling (the bytes are pkcs12.zig's, read back by OpenSSL there).
    // Method: no browser CA yet (E0806); the CA made as the server makes it; a password file
    // other users can read (E0806), an empty one (E0106); a good one writes the file 0600; a
    // second run is refused and leaves it; a revoked name (E0807) writes nothing.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var real: RealClock = .{ .io = io };
    var ca: peer_ca.Ca = undefined;
    var diag: Diag = undefined;
    diag.reset();
    try server_ca.open(&ca, testing.allocator, io, dir, real.clock(), .{ .quiet = true }, &diag);
    const p12 = try std.fs.path.join(arena, &.{ dir, "web-1.p12" });
    const pw = try std.fs.path.join(arena, &.{ dir, "pw" });
    const extra = [_][]const u8{ "--p12", p12, "--password-file", pw };
    try tmp.dir.writeFile(io, .{ .sub_path = "pw", .data = "s3cret\n" });
    try (try tmp.dir.openFile(io, "pw", .{})).setPermissions(io, .fromMode(0o600));

    try testing.expectError(error.Failed, issue_test(arena, dir, &extra, &diag));
    try testing.expectEqual(Code.E0806, diag.code.?);
    var name_buffer: [server_ca.key_name_bytes_max]u8 = undefined;
    diag.reset();
    const key_name = server_ca.key_name_for(null, &name_buffer);
    _ = try browser_ca.open(io, &ca, dir, key_name, .make, true, &diag);

    try (try tmp.dir.openFile(io, "pw", .{})).setPermissions(io, .fromMode(0o644));
    try testing.expectError(error.Failed, issue_test(arena, dir, &extra, &diag));
    try testing.expectEqual(Code.E0806, diag.code.?);
    try tmp.dir.writeFile(io, .{ .sub_path = "pw", .data = "\n" });
    try (try tmp.dir.openFile(io, "pw", .{})).setPermissions(io, .fromMode(0o600));
    try testing.expectError(error.Failed, issue_test(arena, dir, &extra, &diag));
    try testing.expectEqual(Code.E0106, diag.code.?);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "web-1.p12", .{}));

    try tmp.dir.writeFile(io, .{ .sub_path = "pw", .data = "s3cret\n" });
    try issue_test(arena, dir, &extra, &diag);
    const stat = try tmp.dir.statFile(io, "web-1.p12", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    try testing.expectError(error.Failed, issue_test(arena, dir, &extra, &diag));
    try testing.expectEqual(Code.E0806, diag.code.?);
    try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "already exists") != null);
    try testing.expectEqual(stat.size, (try tmp.dir.statFile(io, "web-1.p12", .{})).size);

    try tmp.dir.writeFile(io, .{ .sub_path = server_ca.revoked_file, .data = "web-2\n" });
    // Under the test's directory, so the check that nothing was written there can fail.
    const p12_revoked = try std.fs.path.join(arena, &.{ dir, "web-2.p12" });
    const revoked = [_][]const u8{ "--p12", p12_revoked, "--password-file", pw };
    diag.reset();
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "ca", "issue-client", "web-2", "--scope", "admin" });
    try args.appendSlice(arena, &revoked);
    try args.appendSlice(arena, &.{ "--store", "postgres:host=x", "--state-dir", dir });
    const loaded = try config_mod.load(arena, io, args.items, &diag);
    try testing.expectError(error.Failed, issue(testing.allocator, io, &loaded.ca_issue, &diag));
    try testing.expectEqual(Code.E0807, diag.code.?);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "web-2.p12", .{}));
}
