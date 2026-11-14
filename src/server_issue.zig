//! `zcube-server ca issue-client NAME --scope jobs|admin` and `ca issue-node NAME` (B7 slice 2,
//! docs/mtls.md, docs/decisions/2026-11-13-node-cert-bootstrap.md): signs a client certificate,
//! or a node's first certificate, with the store's CA, on the server host, and writes `NAME.key`
//! (PKCS#8 PEM) and `NAME.crt` (PEM), both mode 0600. Shell code: it reads the state directory
//! and writes the two files. The server need not run; nothing is recorded anywhere, because the
//! scope is in the certificate (identity extension version 2) and revocation is by name
//! (`revoked`).
//!
//! It never makes a CA: a store with no CA key yet is refused (ZC-E0806), so a mistyped
//! `--state-dir` cannot mint a CA nobody trusts. An existing `NAME.key` or `NAME.crt` is refused
//! rather than replaced (the key may be in use) unless `--replace` asks for it: both files are
//! written to temporary names first and then renamed without overwriting, so a failure leaves
//! neither file, and a run killed between the two renames leaves a lone `NAME.key` that a rerun
//! with `--replace` replaces.

const std = @import("std");
const secure_random = @import("secure_random.zig");
const assert = std.debug.assert;
const Ed25519 = std.crypto.sign.Ed25519;
const config_mod = @import("server_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const files = @import("peer_files.zig");
const peer_ca = @import("peer_ca.zig");
const pem_mod = @import("pem.zig");
const server_ca = @import("server_ca.zig");
const RealClock = @import("server_store.zig").RealClock;
const x509 = @import("x509.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

/// A certificate this command writes lives as long as the profile lets a leaf live (seven days):
/// it is re-issued by running the command again with `--replace`.
pub const ttl_ms: u64 = constants.x509_leaf_ttl_ms_max;

pub const Error = error{ Failed, OutOfMemory, Canceled };

/// What was written, for the line the command prints.
pub const Issued = struct {
    not_after_ms: u64,
};

/// Signs and writes the files. On failure `diag` says why.
pub fn issue(
    gpa: Allocator,
    io: std.Io,
    request: *const config_mod.Issue,
    diag: *Diag,
) Error!Issued {
    assert(diag.code == null);
    assert(request.name.len > 0);
    var real: RealClock = .{ .io = io };
    var ca: peer_ca.Ca = undefined;
    try open_ca(&ca, gpa, io, &request.config, real.clock(), diag);

    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    const key = try make_key(io, &seed, diag);
    var certificate: x509.Der = .{};
    const kind: x509.Kind = switch (request.subject) {
        .client => |scope| kind: {
            ca.issue_client_certificate(&certificate, &.{
                .client = request.name,
                .scope = scope,
                .subject_key = key.public_key.toBytes(),
                .ttl_ms = ttl_ms,
            }) catch |err| return refused(diag, request, err);
            break :kind .client;
        },
        .node => kind: {
            const lifetime = ca.window(ttl_ms) catch unreachable; // Seven days from a real clock.
            ca.issue_node_certificate(&certificate, &.{
                .node = request.name,
                .subject_key = key.public_key.toBytes(),
                .lifetime = lifetime,
            }) catch |err| return refused(diag, request, err);
            break :kind .node;
        },
    };
    const parsed = x509.verify(certificate.slice(), ca.public(), ca.wall.now_ms(), .{
        .kind = kind,
        .name = null,
    }) catch unreachable; // The CA just issued it, valid from now for seven days.
    try write_files(io, request, &seed, certificate.slice(), diag);
    return .{ .not_after_ms = parsed.not_after_ms };
}

/// Opens the CA of the store `config` names, the way the server does, but never makes one.
fn open_ca(
    ca: *peer_ca.Ca,
    gpa: Allocator,
    io: std.Io,
    config: *const config_mod.Config,
    wall: @import("clock.zig").Clock,
    diag: *Diag,
) Error!void {
    const directory = @import("server.zig").Server.state_path(config.*, diag) orelse {
        if (diag.code != null) return error.Failed;
        diag.raise(.E0106);
        diag.cause("a memory store's CA lives in the server's memory: there is none to sign", .{});
        diag.fix(.{
            .sentence = "name the store the server runs on",
            .command = "zcube-server ca issue-node NAME --store sqlite:<path>",
        });
        return error.Failed;
    };
    var name_buffer: [server_ca.key_name_bytes_max]u8 = undefined;
    const key_name = try key_name_of(gpa, io, config.store, &name_buffer, diag);
    try key_present(io, directory, key_name, diag);
    server_ca.open(ca, gpa, io, directory, wall, .{
        .key_name = key_name,
        .first_start = false,
        .accept_new = false,
        .quiet = true,
    }, diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.Failed => return error.Failed,
    };
}

/// The CA key's file name for `store`, as `Server.guard` works it out.
fn key_name_of(
    gpa: Allocator,
    io: std.Io,
    store: config_mod.Store,
    buffer: *[server_ca.key_name_bytes_max]u8,
    diag: *Diag,
) Error![]const u8 {
    const file = switch (store) {
        .sqlite => |file| file,
        .memory, .postgres => return server_ca.key_name_for(null, buffer),
    };
    const cwd = std.process.currentPathAlloc(io, gpa) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.raise(.E0806);
        diag.cause("can't tell the working directory to find the CA key: {s}", .{@errorName(err)});
        diag.fix(.{ .sentence = "give the SQLite file as an absolute path" });
        return error.Failed;
    };
    defer gpa.free(cwd);
    const absolute = try std.fs.path.resolveAlloc(gpa, &.{ cwd, file });
    defer gpa.free(absolute);
    return server_ca.key_name_for(absolute, buffer);
}

/// ZC-E0806 unless `directory` holds `key_name`: `server_ca.open` would create the directory and
/// its message would offer `--new-ca`, which is wrong here.
fn key_present(io: std.Io, directory: []const u8, key_name: []const u8, diag: *Diag) Error!void {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{}) catch |err| {
        return no_key(diag, directory, key_name, @errorName(err));
    };
    defer dir.close(io);
    dir.access(io, key_name, .{}) catch |err| {
        return no_key(diag, directory, key_name, @errorName(err));
    };
}

fn no_key(diag: *Diag, directory: []const u8, key_name: []const u8, why: []const u8) Error {
    diag.raise(.E0806);
    diag.cause("no CA key {s} in {s} ({s}): has the server run on this store?", .{
        key_name, directory, why,
    });
    diag.fix(.{ .sentence = "give the --store and --state-dir the server runs with" });
    const first = "if it has not, start the server with this --store first: it makes the CA";
    diag.fix(.{ .sentence = first });
    return error.Failed;
}

fn make_key(io: std.Io, seed: *[32]u8, diag: *Diag) Error!Ed25519.KeyPair {
    // A seed that gives the identity element has a chance of about 2^-250; draw another.
    while (true) {
        secure_random.fill(io, seed, diag, "the client key") catch |err| return switch (err) {
            error.Unavailable => error.Failed,
            error.Canceled => error.Canceled,
        };
        return Ed25519.KeyPair.generateDeterministic(seed.*) catch continue;
    }
}

fn refused(
    diag: *Diag,
    request: *const config_mod.Issue,
    err: peer_ca.IssueCertificateError,
) Error {
    assert(request.name.len > 0);
    switch (err) {
        error.Removed => {
            diag.raise(.E0807);
            diag.cause("{s} is on the server's list of removed names (revoked)", .{request.name});
            diag.fix(.{ .sentence = "take the name out of the revoked file, or choose another" });
        },
        error.BadKey => unreachable, // A fresh key is never the CA's.
        else => |other| x509.raise(diag, @errorCast(other), request.name, &.{}),
    }
    assert(diag.code != null);
    return error.Failed;
}

fn write_files(
    io: std.Io,
    request: *const config_mod.Issue,
    seed: *const [32]u8,
    certificate: []const u8,
    diag: *Diag,
) Error!void {
    const where = request.out_dir;
    var dir = std.Io.Dir.cwd().openDir(io, where, .{}) catch |err| {
        return files.unusable(diag, where, request.name, "open the directory for", @errorName(err));
    };
    defer dir.close(io);
    var key_buffer: [constants.node_name_bytes_max + 4]u8 = undefined;
    var crt_buffer: [constants.node_name_bytes_max + 4]u8 = undefined;
    const key_name = std.fmt.bufPrint(&key_buffer, "{s}.key", .{request.name}) catch
        unreachable; // The CA refused a name longer than a node name.
    const crt_name = std.fmt.bufPrint(&crt_buffer, "{s}.crt", .{request.name}) catch
        unreachable; // As above.
    var text: [pem_mod.bytes_max]u8 = undefined;
    defer std.crypto.secureZero(u8, &text);
    var temps: [2][files.temp_bytes_max]u8 = undefined;
    const key_text = pem_mod.encode_key(&text, seed);
    const key_temp = try files.stage(io, dir, where, key_name, key_text, 0o600, &temps[0], diag);
    defer dir.deleteFile(io, key_temp) catch {}; // Gone once renamed; nothing more to do.
    const crt_text = pem_mod.encode(&text, .certificate, certificate);
    const crt_temp = try files.stage(io, dir, where, crt_name, crt_text, 0o600, &temps[1], diag);
    defer dir.deleteFile(io, crt_temp) catch {}; // As above.
    try install(io, dir, where, key_temp, key_name, request.replace, diag);
    install(io, dir, where, crt_temp, crt_name, request.replace, diag) catch |err| {
        // Not half a pair: the key just put in place goes again. With --replace the old key is
        // gone already; a rerun with --replace writes both.
        if (!request.replace) dir.deleteFile(io, key_name) catch {};
        return err;
    };
    try files.sync_dir(io, dir, where, key_name, diag);
}

/// Renames `temp` to `name`: over an existing `name` only when `replace`.
fn install(
    io: std.Io,
    dir: std.Io.Dir,
    where: []const u8,
    temp: []const u8,
    name: []const u8,
    replace: bool,
    diag: *Diag,
) Error!void {
    assert(temp.len > name.len);
    assert(std.mem.startsWith(u8, temp, name));
    if (replace) {
        dir.rename(temp, dir, name, io) catch |err| {
            return files.unusable(diag, where, name, "write", @errorName(err));
        };
        return;
    }
    dir.renamePreserve(temp, dir, name, io) catch |err| {
        if (err != error.PathAlreadyExists) {
            return files.unusable(diag, where, name, "write", @errorName(err));
        }
        const fix = "run it again with --replace to re-issue, or choose another --out";
        return files.unusable_fix(diag, where, name, "write", "it already exists", fix);
    };
}

const testing = std.testing;
const Code = @import("diag/codes.zig").Code;

fn issue_test(
    arena: Allocator,
    dir: []const u8,
    command: []const []const u8,
    diag: *Diag,
) !Issued {
    diag.reset();
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, command);
    const store = [_][]const u8{ "--store", "postgres:host=x", "--state-dir", dir, "--out", dir };
    try args.appendSlice(arena, &store);
    const loaded = try config_mod.load(arena, testing.io, args.items, diag);
    return issue(testing.allocator, testing.io, &loaded.ca_issue, diag);
}

/// The certificate in `name`.crt, verified as `kind` and `name` against `ca`, and its key's seed
/// in `name`.key matching it; both files 0600.
fn read_back(
    dir: std.Io.Dir,
    ca: *const peer_ca.Ca,
    kind: x509.Kind,
    name: []const u8,
    der_buffer: *[constants.x509_cert_bytes_max]u8,
) !struct { x509.Parsed, []const u8 } {
    const io = testing.io;
    var file_buffer: [constants.node_name_bytes_max + 4]u8 = undefined;
    var text: [pem_mod.bytes_max]u8 = undefined;
    const key_file = try std.fmt.bufPrint(&file_buffer, "{s}.key", .{name});
    const key_text = try dir.readFile(io, key_file, &text);
    var seed: [32]u8 = undefined;
    try testing.expect(pem_mod.decode_key(key_text, &seed));
    const key = try Ed25519.KeyPair.generateDeterministic(seed);
    const crt_file = try std.fmt.bufPrint(&file_buffer, "{s}.crt", .{name});
    const crt_text = try dir.readFile(io, crt_file, &text);
    const der = pem_mod.decode(crt_text, .certificate, der_buffer).?;
    var cluster_buffer: [peer_ca.cluster_bytes]u8 = undefined;
    var uri_buffer: [constants.x509_spiffe_bytes_max]u8 = undefined;
    const identity = @import("x509_identity.zig");
    const path: identity.Path = if (kind == .node) .node else .client;
    const uri = try identity.spiffe_write(&uri_buffer, path, ca.cluster(&cluster_buffer), name);
    const now_ms = ca.wall.now_ms();
    const parsed = try x509.verify(der, ca.public(), now_ms, .{ .kind = kind, .name = uri });
    try testing.expectEqualSlices(u8, &key.public_key.toBytes(), parsed.public_key.of(der));
    for ([_][]const u8{ ".key", ".crt" }) |suffix| {
        const file = try std.fmt.bufPrint(&file_buffer, "{s}{s}", .{ name, suffix });
        const stat = try dir.statFile(io, file, .{});
        try testing.expectEqual(0o600, stat.permissions.toMode() & 0o777);
    }
    return .{ parsed, der };
}

/// The names in `dir`, sorted, for checking that nothing but the pair (no temporary file) is left.
fn names_in(arena: Allocator, dir: std.Io.Dir) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var walker = dir.iterate();
    while (try walker.next(testing.io)) |entry| {
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return names.items;
}

test "ca issue-client writes a 0600 key and certificate the CA signed, and refuses the rest" {
    // Goal: the command of B7 slice 2 end to end over a state directory. Method: refuse with no
    // CA; make one as the server does; issue, then read both files back and verify the
    // certificate's kind, SPIFFE ID, scope and key; then an existing file, a revoked name and a
    // memory store are each refused with their code.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var diag: Diag = undefined;
    const ops_1 = [_][]const u8{ "ca", "issue-client", "ops-1", "--scope", "admin" };
    try testing.expectError(error.Failed, issue_test(arena, dir, &ops_1, &diag));
    try testing.expectEqual(Code.E0806, diag.code.?);
    try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "has the server run") != null);

    var real: RealClock = .{ .io = io };
    var ca: peer_ca.Ca = undefined;
    diag.reset();
    try server_ca.open(&ca, testing.allocator, io, dir, real.clock(), .{ .quiet = true }, &diag);
    const issued = try issue_test(arena, dir, &ops_1, &diag);
    var der_buffer: [constants.x509_cert_bytes_max]u8 = undefined;
    const parsed, const der = try read_back(tmp.dir, &ca, .client, "ops-1", &der_buffer);
    try testing.expectEqual(x509.Scope.admin, parsed.scope(der));
    try testing.expectEqual(issued.not_after_ms, parsed.not_after_ms);

    const ops_1_jobs = [_][]const u8{ "ca", "issue-client", "ops-1", "--scope", "jobs" };
    try testing.expectError(error.Failed, issue_test(arena, dir, &ops_1_jobs, &diag));
    try testing.expectEqual(Code.E0806, diag.code.?);
    try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "already exists") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = server_ca.revoked_file, .data = "ops-2\n" });
    const ops_2 = [_][]const u8{ "ca", "issue-client", "ops-2", "--scope", "jobs" };
    try testing.expectError(error.Failed, issue_test(arena, dir, &ops_2, &diag));
    try testing.expectEqual(Code.E0807, diag.code.?);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "ops-2.key", .{}));

    diag.reset();
    const memory = [_][]const u8{ "ca", "issue-client", "ops-3", "--scope", "jobs" };
    const command = try config_mod.load(arena, io, &memory, &diag);
    const request = &command.ca_issue;
    try testing.expectError(error.Failed, issue(testing.allocator, io, request, &diag));
    try testing.expectEqual(Code.E0106, diag.code.?);
}

test "ca issue-node writes a node certificate, and --replace alone re-issues a pair" {
    // Goal: the node's first certificate (decision 2026-11-13-node-cert-bootstrap.md) and the
    // weekly re-issue. Method: issue-node, verify the node certificate; a second issue-node is
    // refused and leaves the pair as it was; --replace writes a new pair; a lone NAME.key (a run
    // killed between its renames) is refused without --replace and replaced with it; a lone
    // NAME.crt is refused and leaves no NAME.key; no temporary file is ever left; a revoked node.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var real: RealClock = .{ .io = io };
    var ca: peer_ca.Ca = undefined;
    var diag: Diag = undefined;
    diag.reset();
    try server_ca.open(&ca, testing.allocator, io, dir, real.clock(), .{ .quiet = true }, &diag);
    const before = try names_in(arena, tmp.dir);

    const node = [_][]const u8{ "ca", "issue-node", "node-1" };
    _ = try issue_test(arena, dir, &node, &diag);
    var der_buffer: [constants.x509_cert_bytes_max]u8 = undefined;
    const first, const first_der = try read_back(tmp.dir, &ca, .node, "node-1", &der_buffer);
    var first_key: [32]u8 = undefined;
    @memcpy(&first_key, first.public_key.of(first_der));
    try testing.expectEqual(before.len + 2, (try names_in(arena, tmp.dir)).len);

    try testing.expectError(error.Failed, issue_test(arena, dir, &node, &diag));
    try testing.expectEqual(Code.E0806, diag.code.?);
    const kept, const kept_der = try read_back(tmp.dir, &ca, .node, "node-1", &der_buffer);
    try testing.expectEqualSlices(u8, &first_key, kept.public_key.of(kept_der));

    const replace = [_][]const u8{ "ca", "issue-node", "node-1", "--replace" };
    _ = try issue_test(arena, dir, &replace, &diag);
    const again, const again_der = try read_back(tmp.dir, &ca, .node, "node-1", &der_buffer);
    try testing.expect(!std.mem.eql(u8, &first_key, again.public_key.of(again_der)));

    try tmp.dir.deleteFile(io, "node-1.crt");
    try testing.expectError(error.Failed, issue_test(arena, dir, &node, &diag));
    try testing.expectEqual(Code.E0806, diag.code.?);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "node-1.crt", .{}));
    _ = try issue_test(arena, dir, &replace, &diag);
    _ = try read_back(tmp.dir, &ca, .node, "node-1", &der_buffer);

    try tmp.dir.deleteFile(io, "node-1.key");
    try testing.expectError(error.Failed, issue_test(arena, dir, &node, &diag));
    try testing.expectEqual(Code.E0806, diag.code.?);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "node-1.key", .{}));
    try tmp.dir.deleteFile(io, "node-1.crt");
    try testing.expectEqualDeep(before, try names_in(arena, tmp.dir));

    try tmp.dir.writeFile(io, .{ .sub_path = server_ca.revoked_file, .data = "node-2\n" });
    const removed = [_][]const u8{ "ca", "issue-node", "node-2" };
    try testing.expectError(error.Failed, issue_test(arena, dir, &removed, &diag));
    try testing.expectEqual(Code.E0807, diag.code.?);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "node-2.key", .{}));
}
