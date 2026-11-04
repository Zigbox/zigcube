//! M3 of slice 8's review: a peer fetch writes the store the way Zigbox's own pull does, in
//! Zigbox's store namespace, so the files it leaves have the owners and modes Zigbox would give
//! them. Real processes and a real host: `zcube-agent fetch` (from `zig build test`'s install,
//! or `ZCUBE_AGENT_EXE`; skipped without it), a real peer server, real `clone3` and id maps.
//!
//! What the host decides. With `newuidmap`, `newgidmap` and a subordinate range for the user
//! running the test, the namespace maps the full range, and a file of container id 1000 lands as
//! the host id the range gives it, not as host id 1000: a fetch outside the namespace fails the
//! comparison. Without them (the one-id map) every owner is 0 inside, the user outside: run as
//! root that is the same id either way and the test cannot tell; run as another user, a fetch
//! outside the namespace cannot `chown` to 0 and fails. `useradd` gives a new user a range where
//! `/etc/subuid` is set up, so `zig build check`'s run as `tester` usually has the full map.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const zigbox = @import("zigbox");
const agent_peer = @import("agent_peer.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const dir_images = @import("dir_images.zig");
const images_mod = @import("zigbox_images.zig");
const peer = @import("peer.zig");
const peer_server = @import("peer_server.zig");
const peer_stream = @import("peer_stream.zig");

const testing = std.testing;
const store_api = zigbox.store;
const Ed25519 = std.crypto.sign.Ed25519;
const Facts = @FieldType(zigbox.Handle, "facts");
const Sha256 = @FieldType(store_api.image_peer.Options, "expected_manifest");

/// The container id the reference import gives one file, when the map has room for it.
const container_id: u32 = 1000;

/// The group of the one-chunk file: `etc/shadow`'s own, which the object id commits to (Z9).
const shadow_gid: u32 = 42;

/// How long the fetch may take before the test kills it and fails.
const fetch_limit_ms: u64 = 60_000;

/// The reference: what Zigbox writes, done in its namespace from a process of one thread.
const Reference = struct {
    store: *store_api.Store,
    workspace: *store_api.import.Workspace,
    /// The source tree, and the file in it that is given `container_id` inside the namespace.
    source: [:0]const u8,
    owned: [:0]const u8,
    /// A small file, one chunk, given 0:42 as `etc/shadow` is: the peer server reads it outside.
    shadow: [:0]const u8,
    /// Where the child writes the tree's digest.
    pipe_write: i32,

    fn call(context: *anyopaque, squash_owner: bool) u8 {
        const job: *Reference = @ptrCast(@alignCast(context));
        // A one-id map has no id 1000: the file stays 0, as every owner is then.
        _ = linux.fchownat(linux.AT.FDCWD, job.owned, container_id, container_id, 0);
        // Likewise: with a one-id map there is no gid 42 and the file stays 0:0.
        _ = linux.fchownat(linux.AT.FDCWD, job.shadow, 0, shadow_gid, 0);
        var result: store_api.import.Result = undefined;
        var diag: zigbox.diag.Diag = undefined;
        diag.reset();
        const options: store_api.import.Options = .{ .squash_owner = squash_owner, .warn = null };
        store_api.import.import(job.store, job.workspace, job.source, options, &result, &diag) catch
            return 10;
        // The page allocator: this is a fork of a test runner, whose allocator may be locked.
        var images = images_mod.ZigboxImages.open(std.heap.page_allocator, job.store) catch
            return 11;
        defer images.close();
        var buffer: [2048]u8 = undefined;
        const manifest = images_mod.manifest_text;
        const record = images_mod.record_text(&buffer, result.digest, manifest) catch return 12;
        _ = images.import_image(record, result.digest, Sha256.parse(manifest).?) catch return 13;
        const bytes = &result.digest.bytes;
        if (linux.write(job.pipe_write, bytes, bytes.len) != bytes.len) return 14;
        return 0;
    }
};

var reference_facts: Facts = undefined;

/// Imports `job.source` into `job.store` in Zigbox's store namespace and gives the tree. The
/// test runner may have threads, and a namespace needs a process of one: a fork has one.
fn import_reference(job: *Reference, host: zigbox.host.Host) !store_api.Digest {
    var fds: [2]i32 = undefined;
    if (linux.pipe(&fds) != 0) return error.Pipe;
    defer _ = linux.close(fds[0]);
    job.pipe_write = fds[1];
    const forked = linux.fork();
    if (forked == 0) {
        _ = linux.close(fds[0]);
        var diag: zigbox.diag.Diag = undefined;
        diag.reset();
        const work: store_api.namespace.Work = .{ .context = job, .call = Reference.call };
        const code = store_api.namespace.run(host, &reference_facts, work, null, &diag) catch 20;
        linux.exit_group(code);
    }
    _ = linux.close(fds[1]);
    if (@as(isize, @bitCast(forked)) < 0) return error.Fork;
    var raw: i32 = 0;
    _ = linux.waitpid(@intCast(forked), &raw, 0);
    const status: u32 = @bitCast(raw);
    try testing.expect(linux.W.IFEXITED(status));
    try testing.expectEqual(@as(u32, 0), linux.W.EXITSTATUS(status));
    var digest: store_api.Digest = undefined;
    @memset(&digest.bytes, 0xaa);
    const count = linux.read(fds[0], &digest.bytes, digest.bytes.len);
    try testing.expectEqual(digest.bytes.len, count);
    return digest;
}

const Owner = struct { uid: u32, gid: u32, mode: u32 };

fn owner_of(path: [*:0]const u8) !Owner {
    var found: linux.Statx = undefined;
    found.uid = std.math.maxInt(u32);
    const rc = linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{
        .UID = true,
        .GID = true,
        .MODE = true,
    }, &found);
    if (rc != 0) return error.Missing;
    return .{ .uid = found.uid, .gid = found.gid, .mode = found.mode };
}

/// Every file under `<a>/objects` is in `<b>/objects`, with the same host owner and mode, and
/// `b` holds no other: the store a fetch leaves is the one Zigbox left.
fn expect_same_objects(io: std.Io, a: []const u8, b: []const u8) !void {
    var compared: u32 = 0;
    var path_a: [std.fs.max_path_bytes]u8 = undefined;
    var path_b: [std.fs.max_path_bytes]u8 = undefined;
    const objects_a = try std.fmt.bufPrint(&path_a, "{s}/objects", .{a});
    const top = try std.Io.Dir.cwd().openDir(io, objects_a, .{ .iterate = true });
    defer top.close(io);
    var shards = top.iterate();
    for (0..257) |_| {
        const shard = try shards.next(io) orelse break;
        if (shard.kind != .directory) continue;
        const dir = try top.openDir(io, shard.name, .{ .iterate = true });
        defer dir.close(io);
        var files = dir.iterate();
        for (0..1 << 12) |_| {
            const file = try files.next(io) orelse break;
            const name_a = try std.fmt.bufPrintSentinel(&path_a, "{s}/objects/{s}/{s}", .{
                a, shard.name, file.name,
            }, 0);
            const name_b = try std.fmt.bufPrintSentinel(&path_b, "{s}/objects/{s}/{s}", .{
                b, shard.name, file.name,
            }, 0);
            const want = try owner_of(name_a);
            const got = owner_of(name_b) catch |err| {
                std.debug.print("not fetched: {s}\n", .{name_b});
                return err;
            };
            if (want.uid != got.uid or want.gid != got.gid or want.mode != got.mode) {
                std.debug.print("{s}: zigbox {any}, fetch {any}\n", .{ file.name, want, got });
                return error.OwnerDiffers;
            }
            compared += 1;
        }
    }
    try testing.expect(compared >= 3);
    try testing.expectEqual(compared, try count_objects(io, b));
}

fn count_objects(io: std.Io, root: []const u8) !u32 {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const objects = try std.fmt.bufPrint(&path, "{s}/objects", .{root});
    const top = try std.Io.Dir.cwd().openDir(io, objects, .{ .iterate = true });
    defer top.close(io);
    var count: u32 = 0;
    var shards = top.iterate();
    for (0..257) |_| {
        const shard = try shards.next(io) orelse break;
        if (shard.kind != .directory) continue;
        const dir = try top.openDir(io, shard.name, .{ .iterate = true });
        defer dir.close(io);
        var files = dir.iterate();
        for (0..1 << 12) |_| {
            _ = try files.next(io) orelse break;
            count += 1;
        }
    }
    return count;
}

fn find_agent_exe(buffer: []u8) ![]const u8 {
    const given = testing.environ.getPosix("ZCUBE_AGENT_EXE");
    const relative = given orelse "zig-out/bin/zcube-agent";
    const cwd = std.Io.Dir.cwd();
    const length = cwd.realPathFile(testing.io, relative, buffer) catch return error.SkipZigTest;
    return buffer[0..length];
}

/// Writes node `name`'s identity, issued by `ca`, into `state`.
fn make_identity(io: std.Io, state: []const u8, name: []const u8, ca: Ed25519.KeyPair) !void {
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    var opened = try agent_peer.Peer.open(io, state, name, &diag);
    defer opened.close();
    const now = peer_stream.wall_ms(io);
    const key = opened.key.public_key.toBytes();
    opened.credential = peer.issue(ca, name, key, now - 1000, now + 100_000);
    opened.ca_public = ca.public_key.toBytes();
    try opened.store(&diag);
}

/// Runs `argv`, its stderr into `log`, and gives its exit code (killed after `fetch_limit_ms`).
fn run_fetch(io: std.Io, argv: []const []const u8, log: std.Io.File) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    });
    const pid = child.id.?;
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    while (true) {
        var raw: i32 = 0;
        const rc = linux.waitpid(pid, &raw, linux.W.NOHANG);
        const status: u32 = @bitCast(raw);
        if (rc != 0) {
            try testing.expectEqual(@as(usize, @intCast(pid)), rc);
            try testing.expect(linux.W.IFEXITED(status));
            return @intCast(linux.W.EXITSTATUS(status));
        }
        if (std.Io.Clock.awake.now(io).toMilliseconds() - started > fetch_limit_ms) {
            child.kill(io);
            return error.FetchHung;
        }
        try io.sleep(.fromMilliseconds(20), .awake);
    }
}

/// The source tree: `hello`, `etc/plain` and `etc/owned`, which the reference gives container id
/// 1000 and mode 0604. Each is two chunks, so the peer server's read checks it against its chunk
/// list: Zigbox checks a one-chunk object against an id made from the file's owner as the reader
/// sees it, which outside the namespace is the host's (the gap in the decision file, M3). And
/// `owned` can be read by others: a peer server that is not root reads, outside the namespace, a
/// file whose host owner is an id of the user's range (the second gap there).
fn write_source(io: std.Io, dir: std.Io.Dir) !void {
    const bytes = try testing.allocator.alloc(u8, constants.swarm_chunk_bytes + 100);
    defer testing.allocator.free(bytes);
    for ([_][]const u8{ "src/hello", "src/etc/plain", "src/etc/owned" }, 0..) |name, file| {
        for (bytes, 0..) |*byte, at| byte.* = @truncate(at *% 31 +% file);
        try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }
    // One chunk, so `read_chunk` rebuilds its object id from the owner (Zigbox Z9).
    try dir.writeFile(io, .{ .sub_path = "src/etc/shadow", .data = "root:*:20000:0:99999:7:::\n" });
}

/// Runs `zcube-agent fetch` of `tree` from the peer server on `port` into the store at `root_b`.
fn fetch_into(
    io: std.Io,
    dir: std.Io.Dir,
    exe: []const u8,
    state1: []const u8,
    root_b: []const u8,
    tree: store_api.Digest,
    port: u16,
) !void {
    var words: [4][96]u8 = undefined;
    const tree_text = tree.text();
    const named = try std.fmt.bufPrint(&words[0], "node2=127.0.0.1:{d}", .{port});
    const argv = [_][]const u8{
        exe,              "fetch",
        "--node",         "node1",
        "--state-dir",    state1,
        "--zigbox-store", root_b,
        "--manifest",     images_mod.manifest_text,
        "--digest",       &tree_text,
        "--peer",         named,
    };
    const log = try dir.createFile(io, "fetch.log", .{ .read = true });
    defer log.close(io);
    const code = try run_fetch(io, &argv, log);
    if (code != 0) {
        var said: [4096]u8 = undefined;
        const length = try log.readPositionalAll(io, &said, 0);
        std.debug.print("zcube-agent fetch exited {d}:\n{s}\n", .{ code, said[0..length] });
        return error.FetchFailed;
    }
}

fn make_store(store: *store_api.Store, host: zigbox.host.Host, root: []const u8) !void {
    store.at(host, root);
    assert(store.chunk_bytes > 0); // Zigbox's own: the fetch opens the store with it.
    var diag: zigbox.diag.Diag = undefined;
    diag.reset();
    try testing.expect(try store_api.open.check(store, .create, &diag));
}

test "a fetched tree's files have the owners and modes Zigbox's own write gives them" {
    // Goal: M3. The fetch's store writes run in Zigbox's store namespace, so the store it leaves
    // is file for file the one Zigbox leaves. Method: store A is written by Zigbox's import in
    // `namespace.run` (one file given container id 1000 where the map allows); a real peer
    // server serves A; a real `zcube-agent fetch` puts the tree into the empty store B; every
    // object file's host owner and mode in B must equal A's. A fetch that writes outside the
    // namespace leaves host id 1000 (full map) or cannot chown to 0 (a user that is not root).
    const io = testing.io;
    const gpa = testing.allocator;
    var exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try find_agent_exe(&exe_buffer);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buffer[0..try tmp.dir.realPath(io, &base_buffer)];
    for ([_][]const u8{ "src", "src/etc", "a", "b", "images", "state1", "state2" }) |name| {
        try tmp.dir.createDir(io, name, .default_dir);
    }
    try write_source(io, tmp.dir);
    var paths: [7][std.fs.max_path_bytes]u8 = undefined;
    const source = try std.fmt.bufPrintSentinel(&paths[0], "{s}/src", .{base}, 0);
    const owned = try std.fmt.bufPrintSentinel(&paths[1], "{s}/src/etc/owned", .{base}, 0);
    try testing.expectEqual(@as(usize, 0), linux.chmod(owned, 0o604));
    const shadow = try std.fmt.bufPrintSentinel(&paths[6], "{s}/src/etc/shadow", .{base}, 0);
    try testing.expectEqual(@as(usize, 0), linux.chmod(shadow, 0o640));
    const root_a = try std.fmt.bufPrint(&paths[2], "{s}/a/store", .{base});
    const root_b = try std.fmt.bufPrint(&paths[3], "{s}/b/store", .{base});
    const state1 = try std.fmt.bufPrint(&paths[4], "{s}/state1", .{base});
    const state2 = try std.fmt.bufPrint(&paths[5], "{s}/state2", .{base});

    var host_real: zigbox.host_real.HostReal = .{};
    const host = host_real.interface();
    const stores = try gpa.alloc(store_api.Store, 2);
    defer gpa.free(stores);
    try make_store(&stores[0], host, root_a);
    try make_store(&stores[1], host, root_b);
    const workspace = try std.heap.page_allocator.create(store_api.import.Workspace);
    defer std.heap.page_allocator.destroy(workspace);
    var job: Reference = .{
        .store = &stores[0],
        .workspace = workspace,
        .source = source,
        .owned = owned,
        .shadow = shadow,
        .pipe_write = -1,
    };
    const tree = try import_reference(&job, host);

    const ca = try Ed25519.KeyPair.generateDeterministic(@splat(1));
    try make_identity(io, state2, "node2", ca);
    try make_identity(io, state1, "node1", ca);
    var images_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const images = try std.fmt.bufPrint(&images_buffer, "{s}/images", .{base});
    var chunk_dir = try dir_images.DirImages.open(io, gpa, images);
    chunk_dir.close(gpa); // Made, empty: the server needs one beside the Zigbox store.
    const server = try gpa.create(peer_server.Server);
    defer gpa.destroy(server);
    try server.start(io, .{
        .listen = try std.Io.net.IpAddress.parse("127.0.0.1", 0),
        .state_dir = state2,
        .node = "node2",
        .images_path = images,
        .zigbox_store = root_a,
        .quiet = true,
    });
    defer server.stop();

    try fetch_into(io, tmp.dir, exe, state1, root_b, tree, server.port());
    try expect_same_objects(io, root_a, root_b);
}

/// The processes whose command line holds `marker`: the fetch, and the namespace child it made,
/// which is a copy of it.
fn count_marked(io: std.Io, marker: []const u8) !u32 {
    const proc = try std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var count: u32 = 0;
    var entries = proc.iterate();
    for (0..1 << 16) |_| {
        const entry = try entries.next(io) orelse break;
        if (entry.name[0] < '0' or entry.name[0] > '9') continue;
        var path: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&path, "{s}/cmdline", .{entry.name});
        var line: [4096]u8 = undefined;
        const text = proc.readFile(io, name, &line) catch continue; // It has gone.
        if (std.mem.indexOf(u8, text, marker) != null) count += 1;
    }
    return count;
}

test "a fetch killed while its namespace child works leaves no child behind" {
    // Goal: M3, the exit path. The supervisor SIGKILLs a fetch that outlives its deadline; the
    // namespace child must not go on writing the store alone. Method: a peer that accepts the
    // connection and never answers holds the child in its request (10 s); once the fetch and its
    // child are both seen, the fetch is killed, and no process with its arguments may remain.
    const io = testing.io;
    var exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try find_agent_exe(&exe_buffer);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buffer[0..try tmp.dir.realPath(io, &base_buffer)];
    try tmp.dir.createDir(io, "b", .default_dir);
    try tmp.dir.createDir(io, "state1", .default_dir);
    var paths: [2][std.fs.max_path_bytes]u8 = undefined;
    const root_b = try std.fmt.bufPrint(&paths[0], "{s}/b/store", .{base});
    const state1 = try std.fmt.bufPrint(&paths[1], "{s}/state1", .{base});
    var host_real: zigbox.host_real.HostReal = .{};
    var store: store_api.Store = undefined;
    try make_store(&store, host_real.interface(), root_b);
    try make_identity(io, state1, "node1", try Ed25519.KeyPair.generateDeterministic(@splat(1)));
    const silent_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var silent = try silent_address.listen(io, .{});
    defer silent.deinit(io);
    var named: [64]u8 = undefined;
    const peer_arg = try std.fmt.bufPrint(&named, "node2=127.0.0.1:{d}", .{
        silent.socket.address.getPort(),
    });
    const digest = "b3:abababababababababababababababababababababababababababababababab";
    const child = try std.process.spawn(io, .{
        .argv = &.{
            exe,              "fetch",
            "--node",         "node1",
            "--state-dir",    state1,
            "--zigbox-store", root_b,
            "--manifest",     images_mod.manifest_text,
            "--digest",       digest,
            "--peer",         peer_arg,
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var seen: u32 = 0;
    for (0..250) |_| {
        seen = try count_marked(io, state1);
        if (seen == 2) break;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    const pid = child.id.?;
    _ = linux.kill(pid, linux.SIG.KILL); // As the supervisor's deadline does; std sends TERM.
    var raw: i32 = 0;
    try testing.expectEqual(@as(usize, @intCast(pid)), linux.waitpid(pid, &raw, 0));
    try testing.expectEqual(@as(u32, 2), seen);
    for (0..100) |_| {
        seen = try count_marked(io, state1);
        if (seen == 0) break;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    try testing.expectEqual(@as(u32, 0), seen);
}

test "a peer without the tree is named in the fetch's log, with ZC-E0601" {
    // Goal: S3 of slice 8's review. What the supervisor's `fetch.log` gets when no peer has the
    // tree: the line naming the peer that refused the bundle request, and ZC-E0601. Method: a
    // real peer server over an empty store; a real `zcube-agent fetch`, its stderr into a file.
    const io = testing.io;
    const gpa = testing.allocator;
    var exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try find_agent_exe(&exe_buffer);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buffer[0..try tmp.dir.realPath(io, &base_buffer)];
    for ([_][]const u8{ "a", "b", "images", "state1", "state2" }) |name| {
        try tmp.dir.createDir(io, name, .default_dir);
    }
    var paths: [5][std.fs.max_path_bytes]u8 = undefined;
    const root_a = try std.fmt.bufPrint(&paths[0], "{s}/a/store", .{base});
    const root_b = try std.fmt.bufPrint(&paths[1], "{s}/b/store", .{base});
    const state1 = try std.fmt.bufPrint(&paths[2], "{s}/state1", .{base});
    const state2 = try std.fmt.bufPrint(&paths[3], "{s}/state2", .{base});
    const images = try std.fmt.bufPrint(&paths[4], "{s}/images", .{base});
    var host_real: zigbox.host_real.HostReal = .{};
    const stores = try gpa.alloc(store_api.Store, 2);
    defer gpa.free(stores);
    try make_store(&stores[0], host_real.interface(), root_a);
    try make_store(&stores[1], host_real.interface(), root_b);
    const ca = try Ed25519.KeyPair.generateDeterministic(@splat(2));
    try make_identity(io, state2, "node2", ca);
    try make_identity(io, state1, "node1", ca);
    var chunk_dir = try dir_images.DirImages.open(io, gpa, images);
    chunk_dir.close(gpa);
    const server = try gpa.create(peer_server.Server);
    defer gpa.destroy(server);
    try server.start(io, .{
        .listen = try std.Io.net.IpAddress.parse("127.0.0.1", 0),
        .state_dir = state2,
        .node = "node2",
        .images_path = images,
        .zigbox_store = root_a,
        .quiet = true,
    });
    defer server.stop();
    const absent: store_api.Digest = .{ .bytes = @splat(7) };
    const tree_text = absent.text();
    var named_buffer: [64]u8 = undefined;
    const named = try std.fmt.bufPrint(&named_buffer, "node2=127.0.0.1:{d}", .{server.port()});
    const argv = [_][]const u8{
        exe,              "fetch",
        "--node",         "node1",
        "--state-dir",    state1,
        "--zigbox-store", root_b,
        "--manifest",     images_mod.manifest_text,
        "--digest",       &tree_text,
        "--peer",         named,
    };
    const log = try tmp.dir.createFile(io, "fetch.log", .{ .read = true });
    defer log.close(io);
    try testing.expectEqual(constants.exit_external, try run_fetch(io, &argv, log));
    var said: [8192]u8 = undefined;
    const text = said[0..try log.readPositionalAll(io, &said, 0)];
    const refused = "peer node2 answered the bundle request with a status other than 200";
    try testing.expect(std.mem.indexOf(u8, text, refused) != null);
    try testing.expect(std.mem.indexOf(u8, text, "ZC-E0601") != null);
}
