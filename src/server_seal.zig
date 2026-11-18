//! The sealing key's file and its lifecycle (docs/briefs/c5.md, "Sealing and the key's
//! lifecycle"). Shell code: it reads and writes the key file and draws the key from the kernel.
//!
//! The key is `seal-<hash>.key` (or `seal.key`), 0600, beside the CA key, named the way the CA
//! key is (`server_ca.key_name_for`). `open` is the one function that loads it:
//!
//! - No key and no sealed records (a new cluster, or a C3/C4 store upgraded): the key is made.
//! - Sealed records and no key, or a key that does not open one of them: ZC-E0824, naming the
//!   key file, the key id the records expect and the two fixes.
//! - `--discard-sealed`: every sealed record (and every ACME order) is deleted first, then a new
//!   key is made and written, then ZC-W0808 is printed. A crash between the two leaves no sealed
//!   records and the old key, which the next start keeps: nothing is lost that the flag did not
//!   already give up (docs/decisions/2026-11-18-c5-seal-discard-order.md).
//!
//! The start-up check reads through the raw store, so that a store halted by the verified pair
//! (`first_check`) is still checked; the discard writes through the guarded store, so that its
//! deletes advance the remembered pair. Nothing here prints a key: only key ids.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const files = @import("peer_files.zig");
const seal = @import("seal.zig");
const secure_random = @import("secure_random.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

/// `Failed`: `diag` says why (ZC-E0824, ZC-E0806, ZC-E0821 or the store's code).
/// `Canceled`: the task was cancelled while the key was drawn; `diag` is empty.
pub const Error = files.Error || error{ OutOfMemory, Canceled };

pub const key_name_bytes_max = 64;

pub const Options = struct {
    /// The key file's name in the state directory (`key_name_for`).
    key_name: []const u8,
    /// `--discard-sealed`.
    discard: bool = false,
    /// Say nothing on stderr (tests).
    quiet: bool = false,
};

/// The sealing key's file for the CA key file `ca_name`: `ca.key` gives `seal.key`, and
/// `ca-<hash>.key` gives `seal-<hash>.key`, so two stores sharing a state directory never share
/// a sealing key. The name is in `buffer`.
pub fn key_name_for(ca_name: []const u8, buffer: *[key_name_bytes_max]u8) []const u8 {
    assert(std.mem.startsWith(u8, ca_name, "ca"));
    assert(std.mem.endsWith(u8, ca_name, ".key"));
    assert(ca_name.len + 2 <= key_name_bytes_max);
    return std.fmt.bufPrint(buffer, "seal{s}", .{ca_name["ca".len..]}) catch
        unreachable; // Asserted above.
}

/// What the start-up check found: how many sealed records, and the first one the key does not
/// open, if any.
const Scan = struct {
    records: u64 = 0,
    refused: ?Refused = null,

    const Refused = struct {
        key_buffer: [constants.store_key_bytes_max]u8 = undefined,
        key_length: u32 = 0,
        expected: ?seal.KeyId,
        why: []const u8,

        fn key(refused: *const Refused) []const u8 {
            return refused.key_buffer[0..refused.key_length];
        }
    };
};

/// Loads, makes or (with `discard`) replaces the sealing key. `scan` is the raw store, `write`
/// the guarded one; `state_dir` null means a memory store, whose key lives in memory only.
pub fn open(
    gpa: Allocator,
    io: std.Io,
    scan: store.Store,
    write: store.Store,
    state_dir: ?[]const u8,
    options: Options,
    diag: *Diag,
) Error!seal.Key {
    assert(diag.code == null);
    assert(options.key_name.len > 0);
    if (options.discard) return discard(gpa, io, write, state_dir, options, diag);
    var found = try load(io, state_dir, options.key_name, diag);
    errdefer if (found) |*key| key.wipe();
    var result: Scan = .{};
    try check(gpa, scan, if (found) |*key| key else null, &result, diag);
    if (result.refused) |*refused| {
        const found_id: ?seal.KeyId = if (found) |*key| key.id() else null;
        raise_refused(diag, .{
            .state_dir = state_dir,
            .key_name = options.key_name,
            .records = result.records,
            .record = refused.key(),
            .why = refused.why,
            .expected = refused.expected,
            .found = found_id,
        });
        return error.Failed;
    }
    if (found) |key| return key;
    assert(result.records == 0);
    return make(io, state_dir, options.key_name, diag);
}

/// The key in the state directory, or null if there is no file (or no directory: memory).
fn load(io: std.Io, state_dir: ?[]const u8, name: []const u8, diag: *Diag) Error!?seal.Key {
    const path = state_dir orelse return null;
    var dir = try open_dir(io, path, name, diag);
    defer dir.close(io);
    const seed = try files.read_seed(io, dir, path, name, diag) orelse return null;
    return .{ .bytes = seed };
}

/// A new key from the kernel (ZC-E0821 if it fails), written to the state directory if there
/// is one.
fn make(io: std.Io, state_dir: ?[]const u8, name: []const u8, diag: *Diag) Error!seal.Key {
    var key: seal.Key = .{ .bytes = undefined };
    errdefer key.wipe();
    secure_random.fill(io, &key.bytes, diag, "the sealing key") catch |err| return switch (err) {
        error.Unavailable => error.Failed,
        error.Canceled => error.Canceled,
    };
    const path = state_dir orelse return key;
    var dir = try open_dir(io, path, name, diag);
    defer dir.close(io);
    try files.write_seed(io, dir, path, name, key.bytes, diag);
    return key;
}

fn open_dir(io: std.Io, path: []const u8, name: []const u8, diag: *Diag) Error!std.Io.Dir {
    files.make_dir(io, path) catch |err| {
        return files.unusable(diag, path, name, "create the directory for", @errorName(err));
    };
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| {
        return files.unusable(diag, path, name, "open the directory of", @errorName(err));
    };
    errdefer dir.close(io);
    try files.check_dir(io, dir, path, name, diag);
    return dir;
}

/// Opens every sealed record with `key` (or, with no key, notes the first), stopping at the
/// first that does not open. The plaintext is wiped as soon as it is read.
fn check(
    gpa: Allocator,
    scan: store.Store,
    key: ?*const seal.Key,
    result: *Scan,
    diag: *Diag,
) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    for (seal.sealed_prefixes) |prefix| {
        var revision: ?store.Revision = null;
        var after: ?[]const u8 = null;
        var after_buffer: [constants.store_key_bytes_max]u8 = undefined;
        var pages: u32 = 0;
        while (pages < constants.seal_scan_pages_max) : (pages += 1) {
            _ = arena_state.reset(.retain_capacity);
            const page = scan.list(arena_state.allocator(), .{
                .prefix = prefix,
                .at_revision = revision,
                .limit = constants.store_list_limit_max,
                .continue_after = after,
            }, diag) catch return error.Failed;
            revision = page.revision;
            for (page.kvs) |kv| {
                check_one(kv, key, result);
                if (result.refused != null) return;
            }
            const next = page.continue_after orelse break;
            @memcpy(after_buffer[0..next.len], next);
            after = after_buffer[0..next.len];
        } else {
            diag.raise(.E0824);
            diag.cause("more than {d} pages of records under {s}: too many to check", .{
                constants.seal_scan_pages_max, prefix,
            });
            diag.fix(.{ .sentence = "start once with --discard-sealed to remove them" });
            return error.Failed;
        }
    }
}

fn check_one(kv: store.KeyValue, key: ?*const seal.Key, result: *Scan) void {
    assert(result.refused == null);
    // A record with no envelope holds nothing sealed (an entry not yet given a key).
    const envelope = seal.find(kv.value) orelse return;
    result.records += 1;
    const expected = seal.key_id_of(envelope);
    const why: []const u8 = if (key) |k| why: {
        var plain: [constants.seal_plaintext_bytes_max]u8 = undefined;
        defer std.crypto.secureZero(u8, &plain);
        _ = seal.open(k, kv.key, envelope, &plain) catch |err| break :why switch (err) {
            error.Malformed => "it is not a sealed envelope this server can read",
            error.WrongKey => "it was sealed with another key",
            error.Forged => "it does not open with this key (changed, or moved from another key)",
        };
        return;
    } else "there is no key file";
    result.refused = .{ .expected = expected, .why = why };
    const refused = &result.refused.?;
    assert(kv.key.len <= refused.key_buffer.len);
    @memcpy(refused.key_buffer[0..kv.key.len], kv.key);
    refused.key_length = @intCast(kv.key.len);
}

/// What ZC-E0824 names.
pub const Refusal = struct {
    state_dir: ?[]const u8,
    key_name: []const u8,
    /// Sealed records checked, the refused one included.
    records: u64,
    /// The store key of the first record that did not open, and why.
    record: []const u8,
    why: []const u8,
    /// The key id the record names, if its header could be read.
    expected: ?seal.KeyId,
    /// The id of the key file's key, or null if there is no file.
    found: ?seal.KeyId,
};

/// ZC-E0824. Public for the CLI golden test.
pub fn raise_refused(diag: *Diag, refusal: Refusal) void {
    assert(diag.code == null);
    diag.raise(.E0824);
    // Without --verbose only the last cause is shown: it names what the operator acts on, the
    // key id the records expect and the key file; the ones before say which record and why.
    diag.cause("{d} sealed record(s) checked; the rest were not read", .{refusal.records});
    diag.cause("{s} does not open: {s}", .{ refusal.record, refusal.why });
    const expected: []const u8 = if (refusal.expected) |*id| id else "(unreadable)";
    const where = refusal.state_dir orelse "memory";
    if (refusal.found) |*id| {
        diag.cause("the records expect key id {s}; {s}/{s} holds key id {s}", .{
            expected, where, refusal.key_name, id,
        });
    } else {
        diag.cause("the records expect key id {s}; the key file {s}/{s} is missing", .{
            expected, where, refusal.key_name,
        });
    }
    diag.fix(.{ .sentence = "restore the key file from a backup, mode 0600, and start again" });
    diag.fix(.{
        .sentence = "or start once with --discard-sealed: every sealed record is deleted and " ++
            "every public host is ordered again",
        .command = "zcube-server --discard-sealed",
    });
}

/// `--discard-sealed`: deletes the sealed records and the ACME orders, then makes and writes a
/// new key, then warns (ZC-W0808).
fn discard(
    gpa: Allocator,
    io: std.Io,
    write: store.Store,
    state_dir: ?[]const u8,
    options: Options,
    diag: *Diag,
) Error!seal.Key {
    var deleted: u64 = 0;
    for (seal.discarded_prefixes) |prefix| {
        deleted += try delete_all(gpa, write, prefix, diag);
    }
    const key = try make(io, state_dir, options.key_name, diag);
    if (!options.quiet) warn_discarded(io, deleted, key.id());
    return key;
}

/// Deletes every record under `prefix`, `store_txn_ops_max` to a transaction. Returns how many.
fn delete_all(gpa: Allocator, write: store.Store, prefix: []const u8, diag: *Diag) Error!u64 {
    const rounds_max = constants.seal_scan_pages_max *
        (constants.store_list_limit_max / constants.store_txn_ops_max);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var deleted: u64 = 0;
    var round: u32 = 0;
    while (round < rounds_max) : (round += 1) {
        _ = arena_state.reset(.retain_capacity);
        const page = write.list(arena_state.allocator(), .{
            .prefix = prefix,
            .limit = constants.store_txn_ops_max,
        }, diag) catch return error.Failed;
        if (page.kvs.len == 0) return deleted;
        var ops: [constants.store_txn_ops_max]store.Op = undefined;
        var compares: [constants.store_txn_ops_max]store.Compare = undefined;
        for (page.kvs, 0..) |kv, index| {
            ops[index] = .{ .delete = kv.key };
            compares[index] = .{ .key = kv.key, .mod_revision = kv.mod_revision };
        }
        // Compared, so a record rewritten meanwhile is listed and judged again, never lost
        // unseen; a failed compare deletes nothing and the next round lists afresh.
        const result = write.txn(.{
            .compares = compares[0..page.kvs.len],
            .on_success = ops[0..page.kvs.len],
        }, diag) catch return error.Failed;
        if (result.succeeded) deleted += page.kvs.len;
    }
    diag.raise(.E0824);
    diag.cause("{s} still holds records after {d} rounds of deletes", .{ prefix, rounds_max });
    diag.fix(.{ .sentence = "stop whatever writes there, and start with --discard-sealed again" });
    return error.Failed;
}

/// ZC-W0808 on stderr. The id of the new key is printed, never the key.
fn warn_discarded(io: std.Io, deleted: u64, id: seal.KeyId) void {
    var diag: Diag = undefined;
    diag.reset();
    render_warning(&diag, deleted, id);
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    // Verbose: every cause matters once (the count, the new key's id, the limits), and the text
    // mode shows only the last.
    const text = diag_mod.render(&diagnostic, .verbose, false, &buffer);
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to say it.
}

/// The warning's diagnostic, apart so that tests can render it.
pub fn render_warning(diag: *Diag, deleted: u64, id: seal.KeyId) void {
    assert(diag.code == null);
    diag.raise(.W0808);
    diag.cause("--discard-sealed deleted {d} sealed record(s) and ACME order(s)", .{deleted});
    diag.cause("a new sealing key was made, with id {s}", .{&id});
    diag.cause("every public host is ordered again, which counts against Let's Encrypt's " ++
        "limits: 50 certificates per registered domain and 5 duplicates per week", .{});
    diag.fix(.{
        .sentence = "back up the new key file; start without --discard-sealed from now on",
    });
}

// ---- Tests ---------------------------------------------------------------------------------

const testing = std.testing;
const clock_mod = @import("clock.zig");
const codes = @import("diag/codes.zig");
const redaction = @import("testing/redaction.zig");
const store_memory = @import("store_memory.zig");

const TestRig = struct {
    tmp: std.testing.TmpDir,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    path_length: u32 = 0,
    manual: clock_mod.ManualClock = .{ .ms = 1_000 },
    memory: store_memory.MemoryStore = undefined,
    diag: Diag = undefined,
    nonces: u64 = 0,

    /// In place: the memory store keeps a pointer to the clock.
    fn init(rig: *TestRig, io: std.Io) !void {
        rig.* = .{ .tmp = std.testing.tmpDir(.{}) };
        // A state directory is 0700 whatever the runner's umask (as in server_ca's tests).
        try rig.tmp.dir.setFilePermissions(io, ".", .fromMode(0o700), .{});
        rig.path_length = @intCast(try rig.tmp.dir.realPath(io, &rig.path_buffer));
        rig.memory.init(testing.allocator, rig.manual.clock());
        rig.diag.reset();
    }

    fn deinit(rig: *TestRig) void {
        rig.memory.deinit();
        rig.tmp.cleanup();
    }

    fn path(rig: *const TestRig) []const u8 {
        return rig.path_buffer[0..rig.path_length];
    }

    fn open_key(rig: *TestRig, discard_sealed: bool) Error!seal.Key {
        const s = rig.memory.interface();
        return open(testing.allocator, testing.io, s, s, rig.path(), .{
            .key_name = "seal.key",
            .discard = discard_sealed,
            .quiet = true,
        }, &rig.diag);
    }

    fn put(rig: *TestRig, key: []const u8, value: []const u8) !void {
        const ops = [_]store.Op{.{ .put = .{ .key = key, .value = value } }};
        const result = try rig.memory.interface().txn(.{ .on_success = &ops }, &rig.diag);
        try testing.expect(result.succeeded);
    }

    /// A record as later slices write one: clear members and the sealed key.
    fn put_sealed(rig: *TestRig, key: *const seal.Key, path_: []const u8, plain: []const u8) !void {
        // Distinct per record; a test needs no randomness here.
        rig.nonces += 1;
        var nonce: [seal.nonce_bytes]u8 = @splat(0);
        std.mem.writeInt(u64, nonce[0..8], rig.nonces, .little);
        var envelope: [seal.envelope_bytes_max]u8 = undefined;
        const sealed = seal.seal(key, path_, plain, nonce, &envelope);
        var value: [seal.envelope_bytes_max + 64]u8 = undefined;
        const text = try std.fmt.bufPrint(&value, "{{\"v\":1,\"key\":\"{s}\",\"state\":\"ok\"}}", .{
            sealed,
        });
        try rig.put(path_, text);
    }

    fn count(rig: *TestRig, prefix: []const u8) !usize {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const page = try rig.memory.interface().list(arena.allocator(), .{
            .prefix = prefix,
            .limit = constants.store_list_limit_max,
        }, &rig.diag);
        return page.kvs.len;
    }

    /// The rendered diagnostic, for checking what it names and that it holds no key.
    fn rendered(rig: *TestRig, buffer: *[constants.diag_output_bytes_max]u8) []const u8 {
        var diagnostic: diag_mod.Diagnostic = undefined;
        diag_mod.to_diagnostic(&diagnostic, &rig.diag);
        return diag_mod.render(&diagnostic, .text, false, buffer);
    }

    fn key_file(rig: *TestRig) !?[32]u8 {
        return files.read_seed(testing.io, rig.tmp.dir, "tmp", "seal.key", &rig.diag);
    }
};

const plain_key = "-----not a real P-256 key, but planted for the redaction checks-----";

test "a C4 store is upgraded: the key is made 0600 and kept, and nothing is refused" {
    // Goal: "no key and no sealed records" just works, and the key outlives a restart. Method: a
    // store with C4 records and no sealed ones; open twice and compare.
    var rig: TestRig = undefined;
    try rig.init(testing.io);
    defer rig.deinit();
    try rig.put("/services/hello", "{\"v\":3,\"name\":\"hello\"}");
    var first = try rig.open_key(false);
    defer first.wipe();
    var second = try rig.open_key(false);
    defer second.wipe();
    try testing.expectEqualSlices(u8, &first.bytes, &second.bytes);
    try testing.expectEqualSlices(u8, &first.bytes, &(try rig.key_file()).?);
    const file = try rig.tmp.dir.openFile(testing.io, "seal.key", .{});
    defer file.close(testing.io);
    const stat = try file.stat(testing.io);
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    try testing.expectEqual(@as(usize, 1), try rig.count("/services/"));
}

test "sealed records with the key removed, or another key, are ZC-E0824 naming the key id" {
    // Goal: the server never starts over records it cannot open. Method: seal a record, then
    // remove the key file, then put another key in its place; each start is refused with the
    // key file and the expected key id named, and no key in the text.
    var rig: TestRig = undefined;
    try rig.init(testing.io);
    defer rig.deinit();
    var key = try rig.open_key(false);
    defer key.wipe();
    try rig.put_sealed(&key, "/edge-certs/a.example", plain_key);
    try rig.put_sealed(&key, "/acme-account/0123abcd", plain_key);
    var again = try rig.open_key(false);
    again.wipe();

    try rig.tmp.dir.deleteFile(testing.io, "seal.key");
    try testing.expectError(error.Failed, rig.open_key(false));
    try testing.expectEqual(codes.Code.E0824, rig.diag.code.?);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    var text = rig.rendered(&buffer);
    const id = key.id();
    try testing.expect(std.mem.indexOf(u8, text, &id) != null);
    try testing.expect(std.mem.indexOf(u8, text, "seal.key is missing") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--discard-sealed") != null);
    try redaction.expect_absent(text, &key.bytes, "E0824, no key");
    try redaction.expect_absent(text, plain_key, "E0824, no key");
    // Nothing was made in its place: a refused start writes no key.
    try testing.expect((try rig.key_file()) == null);

    rig.diag.reset();
    var other: [32]u8 = @splat(0x42);
    try files.write_seed(testing.io, rig.tmp.dir, "tmp", "seal.key", other, &rig.diag);
    try testing.expectError(error.Failed, rig.open_key(false));
    try testing.expectEqual(codes.Code.E0824, rig.diag.code.?);
    text = rig.rendered(&buffer);
    try testing.expect(std.mem.indexOf(u8, text, &id) != null);
    try testing.expect(std.mem.indexOf(u8, text, &files_id(other)) != null);
    try redaction.expect_absent(text, &key.bytes, "E0824, other key");
    try redaction.expect_absent(text, &other, "E0824, other key");
    rig.diag.reset();
    try testing.expectEqual(@as(usize, 1), try rig.count("/edge-certs/"));
}

test "a moved record and a tampered record are refused at start" {
    // Goal: the store key is bound into each record. Method: copy a sealed value to another
    // host's key; then flip one byte of a value's ciphertext. Each start is ZC-E0824.
    var rig: TestRig = undefined;
    try rig.init(testing.io);
    defer rig.deinit();
    var key = try rig.open_key(false);
    defer key.wipe();
    try rig.put_sealed(&key, "/edge-certs/a.example", plain_key);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const kv = (try rig.memory.interface().get(
        arena.allocator(),
        "/edge-certs/a.example",
        null,
        &rig.diag,
    )).kv.?;
    try rig.put("/edge-certs/b.example", kv.value);
    try testing.expectError(error.Failed, rig.open_key(false));
    try testing.expectEqual(codes.Code.E0824, rig.diag.code.?);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, rig.rendered(&buffer), &key.id()) != null);
    // The record is named in the full cause chain (--verbose).
    try testing.expect(cause_holds(&rig.diag, "/edge-certs/b.example"));

    rig.diag.reset();
    try rig.put("/edge-certs/b.example", "{\"v\":1,\"state\":\"pending\"}");
    var ok = try rig.open_key(false);
    ok.wipe();
    const tampered = try arena.allocator().dupe(u8, kv.value);
    const envelope_at = std.mem.indexOf(u8, tampered, seal.magic).?;
    const at = envelope_at + seal.header_bytes + 10;
    tampered[at] = if (tampered[at] == 'A') 'B' else 'A';
    try rig.put("/edge-certs/a.example", tampered);
    try testing.expectError(error.Failed, rig.open_key(false));
    try testing.expectEqual(codes.Code.E0824, rig.diag.code.?);
}

test "--discard-sealed deletes the sealed records and orders, makes a new key and warns" {
    // Goal: the way out of ZC-E0824. Method: seal records under each discarded prefix (more than
    // one transaction's worth), lose the key, start with the flag: they are gone, other records
    // stay, a new key is written, and the next plain start opens with it. W0808's text names the
    // new key's id and the limits, never the key.
    var rig: TestRig = undefined;
    try rig.init(testing.io);
    defer rig.deinit();
    var old = try rig.open_key(false);
    defer old.wipe();
    var name: [64]u8 = undefined;
    for (0..constants.store_txn_ops_max + 3) |index| {
        const host = try std.fmt.bufPrint(&name, "/edge-certs/h{d}.example", .{index});
        try rig.put_sealed(&old, host, plain_key);
    }
    try rig.put_sealed(&old, "/acme-account/0123abcd", plain_key);
    try rig.put("/acme-orders/h1.example", "{\"v\":1}");
    try rig.put("/services/hello", "{\"v\":3}");
    try rig.tmp.dir.deleteFile(testing.io, "seal.key");
    try testing.expectError(error.Failed, rig.open_key(false));
    rig.diag.reset();

    var fresh = try rig.open_key(true);
    defer fresh.wipe();
    try testing.expect(!std.mem.eql(u8, &old.bytes, &fresh.bytes));
    try testing.expectEqualSlices(u8, &fresh.bytes, &(try rig.key_file()).?);
    for (seal.discarded_prefixes) |prefix| {
        try testing.expectEqual(@as(usize, 0), try rig.count(prefix));
    }
    try testing.expectEqual(@as(usize, 1), try rig.count("/services/"));

    var next = try rig.open_key(false);
    defer next.wipe();
    try testing.expectEqualSlices(u8, &fresh.bytes, &next.bytes);
    // A sealed record written with the new key opens at the next start. (The new order itself
    // is the ACME shell's, slice 3b: docs/decisions/2026-11-18-c5-seal-discard-order.md.)
    try rig.put_sealed(&fresh, "/edge-certs/h1.example", plain_key);
    var after = try rig.open_key(false);
    after.wipe();

    var warning: Diag = undefined;
    warning.reset();
    render_warning(&warning, 21, fresh.id());
    try testing.expectEqual(codes.Code.W0808, warning.code.?);
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &warning);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const text = diag_mod.render(&diagnostic, .verbose, false, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, &fresh.id()) != null);
    try testing.expect(std.mem.indexOf(u8, text, "50 certificates") != null);
    try redaction.expect_absent(text, &fresh.bytes, "W0808");
}

test "the sealing key is named after the CA key" {
    var buffer: [key_name_bytes_max]u8 = undefined;
    try testing.expectEqualStrings("seal.key", key_name_for("ca.key", &buffer));
    try testing.expectEqualStrings(
        "seal-0123456789abcdef.key",
        key_name_for("ca-0123456789abcdef.key", &buffer),
    );
}

fn files_id(bytes: [32]u8) seal.KeyId {
    const key: seal.Key = .{ .bytes = bytes };
    return key.id();
}

fn cause_holds(diag: *Diag, needle: []const u8) bool {
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const text = diag_mod.render(&diagnostic, .verbose, false, &buffer);
    return std.mem.indexOf(u8, text, needle) != null;
}
