//! The sealing key's file and its lifecycle (docs/briefs/c5.md, "Sealing and the key's
//! lifecycle"). Shell code: it reads and writes the key file and draws the key from the kernel.
//!
//! The key is `seal-<hash>.key` (or `seal.key`), 0600, beside the CA key, named the way the CA
//! key is (`server_ca.key_name_for`). `open` is the one function that loads it:
//!
//! - No key and no sealed records (a new cluster, or a C3/C4 store upgraded): the key is made,
//!   never over a key another start wrote meanwhile (that one is read instead).
//! - Sealed records and no key, or a key that does not open one of them: ZC-E0824, naming the
//!   key file, the key id the records expect and the two fixes.
//! - `--discard-sealed` acts only then. With a key that opens every sealed record it deletes
//!   nothing, keeps the key and says so (ZC-W0808, "nothing to discard"). Otherwise `open` only
//!   plans the discard, and `discard` carries it out once every start step that can refuse has
//!   passed: the sealed records (and every ACME order) are deleted, the old key file is renamed
//!   aside (`<name>.discarded-<unix seconds>`, still 0600), a new key is written and ZC-W0808 is
//!   printed (docs/decisions/2026-11-18-c5-seal-fix-discard-and-find.md).
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
/// A key name, ".discarded-" and a count of seconds.
pub const aside_name_bytes_max = key_name_bytes_max + ".discarded-".len + 20;

/// The most records the start-up check reads under one prefix, and so the most `--discard-sealed`
/// is ever asked to delete under one: 4096 pages of 500, 2,048,000.
pub const scan_records_max: u64 =
    @as(u64, constants.seal_scan_pages_max) * constants.store_list_limit_max;

/// The discard's rounds of `store_txn_ops_max` deletes under one prefix: enough for every record
/// the scan admits, plus one failed compare (a record rewritten meanwhile) per page.
const discard_rounds_max: u64 =
    (scan_records_max + constants.store_txn_ops_max - 1) / constants.store_txn_ops_max +
    constants.seal_scan_pages_max;

comptime {
    assert(scan_records_max == 2_048_000);
    assert((discard_rounds_max - constants.seal_scan_pages_max) *
        constants.store_txn_ops_max >= scan_records_max);
}

pub const Options = struct {
    /// The key file's name in the state directory (`key_name_for`).
    key_name: []const u8,
    /// `--discard-sealed`.
    discard: bool = false,
    /// Say nothing on stderr (tests).
    quiet: bool = false,
};

/// What `open` decided.
pub const Opened = union(enum) {
    /// The start goes on with this key.
    ready: seal.Key,
    /// `--discard-sealed`, and the key does not open the sealed records: `discard` deletes them
    /// and makes the key, after every start step that can refuse.
    discard,
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

/// Loads or makes the sealing key, or (with `discard`, when the key does not open the sealed
/// records) plans the discard. `scan` is the raw store; `state_dir` null means a memory store,
/// whose key lives in memory only. Deletes nothing.
pub fn open(
    gpa: Allocator,
    io: std.Io,
    scan: store.Store,
    state_dir: ?[]const u8,
    options: Options,
    diag: *Diag,
) Error!Opened {
    assert(diag.code == null);
    assert(options.key_name.len > 0);
    var found = try load(io, state_dir, options.key_name, diag);
    defer if (found) |*key| key.wipe();
    var result: Scan = .{};
    try check(gpa, scan, if (found) |*key| key else null, &result, diag);
    if (result.refused) |*refused| {
        if (options.discard) {
            // Planned first, so that the discard can finish: every prefix it empties is within
            // the bound its rounds are sized for.
            for (seal.discarded_prefixes) |prefix| {
                var counter: Counter = .{};
                try walk(gpa, scan, prefix, &counter, diag);
            }
            return .discard;
        }
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
    if (options.discard and !options.quiet) warn_nothing(io);
    if (found) |key| return .{ .ready = key };
    assert(result.records == 0);
    return .{ .ready = try make(io, state_dir, options.key_name, diag) };
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
/// is one. The file is never replaced: if another start wrote one first, that key is read and
/// returned instead, so two racing starts agree on one key.
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
    if (try files.write_seed_new(io, dir, path, name, key.bytes, diag)) return key;
    key.wipe();
    const seed = try files.read_seed(io, dir, path, name, diag) orelse {
        return files.unusable(diag, path, name, "read", "it was written and then removed");
    };
    return .{ .bytes = seed };
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
    for (seal.sealed_prefixes) |prefix| {
        var checker: Checker = .{ .key = key, .result = result };
        try walk(gpa, scan, prefix, &checker, diag);
        if (result.refused != null) return;
    }
}

const Checker = struct {
    key: ?*const seal.Key,
    result: *Scan,

    fn visit(checker: *Checker, kv: store.KeyValue) bool {
        check_one(kv, checker.key, checker.result);
        return checker.result.refused == null;
    }
};

const Counter = struct {
    records: u64 = 0,

    fn visit(counter: *Counter, kv: store.KeyValue) bool {
        _ = kv;
        counter.records += 1;
        return true;
    }
};

/// Lists every record under `prefix` at one revision, page by page, handing each to
/// `visitor.visit` until it returns false. More than `scan_records_max` records is ZC-E0824:
/// the start is refused, never half-checked.
fn walk(
    gpa: Allocator,
    scan: store.Store,
    prefix: []const u8,
    visitor: anytype,
    diag: *Diag,
) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
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
            if (!visitor.visit(kv)) return;
        }
        const next = page.continue_after orelse return;
        @memcpy(after_buffer[0..next.len], next);
        after = after_buffer[0..next.len];
    }
    raise_too_many(diag, prefix);
    return error.Failed;
}

/// ZC-E0824 for a prefix past the bound: one cause naming the bound and what was found, and a
/// fix that is not `--discard-sealed` (which would delete every one of them). Public for the
/// CLI golden test.
pub fn raise_too_many(diag: *Diag, prefix: []const u8) void {
    assert(diag.code == null);
    diag.raise(.E0824);
    diag.cause("more than {d} records under {s}; the start-up check reads at most {d} " ++
        "({d} pages of {d}), so it refuses to start rather than check part of them", .{
        scan_records_max,              prefix,                         scan_records_max,
        constants.seal_scan_pages_max, constants.store_list_limit_max,
    });
    diag.fix(.{ .sentence = "delete the records under that prefix that no public host uses " ++
        "any more, then start again" });
}

fn check_one(kv: store.KeyValue, key: ?*const seal.Key, result: *Scan) void {
    assert(result.refused == null);
    // Every envelope in the value is checked; a record with none holds nothing sealed (an
    // entry not yet given a key).
    var envelopes = seal.envelopes(kv.value);
    var counted = false;
    while (envelopes.next()) |envelope| {
        if (!counted) result.records += 1;
        counted = true;
        const why = refusal_of(envelope, kv.key, key) orelse continue;
        result.refused = .{ .expected = seal.key_id_of(envelope), .why = why };
        const refused = &result.refused.?;
        assert(kv.key.len <= refused.key_buffer.len);
        @memcpy(refused.key_buffer[0..kv.key.len], kv.key);
        refused.key_length = @intCast(kv.key.len);
        return;
    }
}

/// Why `envelope` at `path` does not open with `key`, or null if it opens.
fn refusal_of(envelope: []const u8, path: []const u8, key: ?*const seal.Key) ?[]const u8 {
    const k = key orelse return "there is no key file";
    var plain: [constants.seal_plaintext_bytes_max]u8 = undefined;
    defer std.crypto.secureZero(u8, &plain);
    _ = seal.open(k, path, envelope, &plain) catch |err| return switch (err) {
        error.Malformed => "it is not a sealed envelope this server can read",
        error.WrongKey => "it was sealed with another key",
        error.Forged => "it does not open with this key (changed, or moved from another key)",
    };
    return null;
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
    // The directory comes last: a cause is a fixed-size text, and a long path is what is cut.
    diag.cause("{d} sealed record(s) checked; the rest were not read", .{refusal.records});
    diag.cause("{s} does not open: {s}", .{ refusal.record, refusal.why });
    const expected: []const u8 = if (refusal.expected) |*id| id else "(unreadable)";
    const where = refusal.state_dir orelse "memory";
    if (refusal.found) |*id| {
        diag.cause("the records expect key id {s}; {s} holds key id {s}, in {s}", .{
            expected, refusal.key_name, id, where,
        });
    } else {
        diag.cause("the records expect key id {s}; {s} is missing from {s}", .{
            expected, refusal.key_name, where,
        });
    }
    diag.fix(.{ .sentence = "restore the key file from a backup, mode 0600, and start again" });
    diag.fix(.{
        .sentence = "or start once with --discard-sealed: every sealed record is deleted and " ++
            "every public host is ordered again",
        .command = "zcube-server --discard-sealed",
    });
}

/// Carries out the discard `open` planned: deletes the sealed records and the ACME orders, then
/// renames the old key file aside, then makes and writes a new key, then warns (ZC-W0808). The
/// server calls it after every start step that can refuse. A crash part way leaves either the
/// old key and fewer records, or no key and no records: the next start, with the flag or
/// without, is never worse off.
pub fn discard(
    gpa: Allocator,
    io: std.Io,
    write: store.Store,
    state_dir: ?[]const u8,
    options: Options,
    diag: *Diag,
) Error!seal.Key {
    assert(diag.code == null);
    assert(options.discard);
    var deleted: u64 = 0;
    for (seal.discarded_prefixes) |prefix| {
        deleted += try delete_all(gpa, write, prefix, diag);
    }
    var aside_buffer: [aside_name_bytes_max]u8 = undefined;
    const aside = try set_aside(io, state_dir, options.key_name, &aside_buffer, diag);
    const key = try make(io, state_dir, options.key_name, diag);
    if (!options.quiet) warn_discarded(io, deleted, key.id(), aside);
    return key;
}

/// Renames the key file to `<name>.discarded-<unix seconds>`, never over another file, and
/// returns the new name; null if there is no key file (or no directory: memory).
fn set_aside(
    io: std.Io,
    state_dir: ?[]const u8,
    name: []const u8,
    buffer: *[aside_name_bytes_max]u8,
    diag: *Diag,
) Error!?[]const u8 {
    const path = state_dir orelse return null;
    var dir = try open_dir(io, path, name, diag);
    defer dir.close(io);
    dir.access(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return files.unusable(diag, path, name, "read", @errorName(err)),
    };
    const seconds = @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000);
    const aside = std.fmt.bufPrint(buffer, "{s}.discarded-{d}", .{ name, seconds }) catch
        unreachable; // A name of at most key_name_bytes_max and a 64-bit count.
    if (!try files.rename_new(io, dir, path, name, aside, diag)) {
        return files.unusable(diag, path, aside, "keep the old key as", "that file exists");
    }
    try files.sync_dir(io, dir, path, aside, diag);
    return aside;
}

/// Deletes every record under `prefix`, `store_txn_ops_max` to a transaction. Returns how many.
fn delete_all(gpa: Allocator, write: store.Store, prefix: []const u8, diag: *Diag) Error!u64 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var deleted: u64 = 0;
    var round: u64 = 0;
    while (round < discard_rounds_max) : (round += 1) {
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
    raise_unfinished(diag, prefix);
    return error.Failed;
}

/// ZC-E0824 for a discard that could not finish: something kept writing under `prefix`. The fix
/// is not the flag, which the operator is already using. Public for the CLI golden test.
pub fn raise_unfinished(diag: *Diag, prefix: []const u8) void {
    assert(diag.code == null);
    diag.raise(.E0824);
    diag.cause("--discard-sealed could not empty {s}: records kept appearing there after {d} " ++
        "rounds of deletes, so another writer is at work; the old key file is unchanged", .{
        prefix, discard_rounds_max,
    });
    diag.fix(.{ .sentence = "stop every other zcube-server on this store, then start again" });
}

/// ZC-W0808 on stderr, rendered verbose: every cause matters once (the count, the new key's id,
/// where the old key went, the limits), and the text mode shows only the last.
fn warn(io: std.Io, diag: *Diag) void {
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const text = diag_mod.render(&diagnostic, .verbose, false, &buffer);
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to say it.
}

fn warn_discarded(io: std.Io, deleted: u64, id: seal.KeyId, aside: ?[]const u8) void {
    var diag: Diag = undefined;
    diag.reset();
    render_warning(&diag, deleted, id, aside);
    warn(io, &diag);
}

fn warn_nothing(io: std.Io) void {
    var diag: Diag = undefined;
    diag.reset();
    render_nothing(&diag);
    warn(io, &diag);
}

/// The warning's diagnostic, apart so that tests can render it. The id of the new key is
/// printed, never the key; `aside` is the old key file's new name, if there was one.
pub fn render_warning(diag: *Diag, deleted: u64, id: seal.KeyId, aside: ?[]const u8) void {
    assert(diag.code == null);
    diag.raise(.W0808);
    diag.cause("--discard-sealed deleted {d} sealed record(s) and ACME order(s)", .{deleted});
    if (aside) |name| {
        diag.cause("the old key file was renamed {s}, beside the new one (docs/sealing.md " ++
            "says how to restore it)", .{name});
    }
    diag.cause("a new sealing key was made, with id {s}", .{&id});
    diag.cause("every public host is ordered again, which counts against Let's Encrypt's " ++
        "limits: 50 certificates per registered domain per week and 5 duplicates per " ++
        "week", .{});
    diag.fix(.{
        .sentence = "back up the new key file; start without --discard-sealed from now on",
    });
}

/// ZC-W0808 when the key opens every sealed record: the flag did nothing.
pub fn render_nothing(diag: *Diag) void {
    assert(diag.code == null);
    diag.raise(.W0808);
    diag.cause("--discard-sealed: the sealing key opens every sealed record, so nothing was " ++
        "deleted and the key was kept", .{});
    diag.fix(.{ .sentence = "nothing to discard; remove --discard-sealed" });
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

    fn options(discard_sealed: bool) Options {
        return .{ .key_name = "seal.key", .discard = discard_sealed, .quiet = true };
    }

    /// `open`, then the planned discard if there is one, as the server does.
    fn open_key(rig: *TestRig, discard_sealed: bool) Error!seal.Key {
        const s = rig.memory.interface();
        const o = options(discard_sealed);
        return switch (try open(testing.allocator, testing.io, s, rig.path(), o, &rig.diag)) {
            .ready => |key| key,
            .discard => discard(testing.allocator, testing.io, s, rig.path(), o, &rig.diag),
        };
    }

    /// `open` alone.
    fn plan(rig: *TestRig, discard_sealed: bool) Error!Opened {
        const s = rig.memory.interface();
        const o = options(discard_sealed);
        return open(testing.allocator, testing.io, s, rig.path(), o, &rig.diag);
    }

    /// The names in the state directory that start with "seal.key.discarded-".
    fn asides(rig: *TestRig, first: *[aside_name_bytes_max]u8) !usize {
        var dir = try rig.tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
        defer dir.close(testing.io);
        var iterator = dir.iterate();
        var found: usize = 0;
        while (try iterator.next(testing.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "seal.key.discarded-")) continue;
            if (found == 0) @memcpy(first[0..entry.name.len], entry.name);
            found += 1;
        }
        return found;
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
    try expect_redacted_all(&rig.diag, &key.bytes, plain_key);
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
    try expect_redacted_all(&rig.diag, &key.bytes, plain_key);
    try expect_redacted_all(&rig.diag, &other, plain_key);
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
    render_warning(&warning, 21, fresh.id(), "seal.key.discarded-1700000000");
    try testing.expectEqual(codes.Code.W0808, warning.code.?);
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &warning);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const text = diag_mod.render(&diagnostic, .verbose, false, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, &fresh.id()) != null);
    try testing.expect(std.mem.indexOf(u8, text, "50 certificates") != null);
    try testing.expect(std.mem.indexOf(u8, text, "seal.key.discarded-1700000000") != null);
    try redaction.expect_absent(text, &fresh.bytes, "W0808");
}

test "--discard-sealed with a key that opens every record deletes nothing and keeps the key" {
    // Goal: the flag acts only when the start check fails (ruling 1). Method: seal records with
    // the key in place and start with the flag: every record and the key file are as they were,
    // no file is set aside, and W0808's other text says to remove the flag.
    var rig: TestRig = undefined;
    try rig.init(testing.io);
    defer rig.deinit();
    var key = try rig.open_key(false);
    defer key.wipe();
    try rig.put_sealed(&key, "/edge-certs/a.example", plain_key);
    try rig.put("/acme-orders/a.example", "{\"v\":1}");
    var again = try rig.open_key(true);
    defer again.wipe();
    try testing.expectEqualSlices(u8, &key.bytes, &again.bytes);
    try testing.expectEqualSlices(u8, &key.bytes, &(try rig.key_file()).?);
    try testing.expectEqual(@as(usize, 1), try rig.count("/edge-certs/"));
    try testing.expectEqual(@as(usize, 1), try rig.count("/acme-orders/"));
    var name: [aside_name_bytes_max]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try rig.asides(&name));

    var warning: Diag = undefined;
    warning.reset();
    render_nothing(&warning);
    try testing.expectEqual(codes.Code.W0808, warning.code.?);
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &warning);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const text = diag_mod.render(&diagnostic, .text, false, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, "nothing to discard; remove --discard-sealed") !=
        null);
}

test "--discard-sealed renames the old key aside, 0600, and a planned discard deletes nothing" {
    // Goal: the old key is never overwritten, and a start refused after `open` (CA, listeners)
    // deletes nothing (ruling 1). Method: another key in place of the sealing key; `open` with
    // the flag plans the discard and the records are all still there; then the discard runs and
    // the old key is found, unchanged and 0600, under its aside name.
    var rig: TestRig = undefined;
    try rig.init(testing.io);
    defer rig.deinit();
    var key = try rig.open_key(false);
    defer key.wipe();
    try rig.put_sealed(&key, "/edge-certs/a.example", plain_key);
    try rig.put("/acme-orders/a.example", "{\"v\":1}");
    rig.diag.reset();
    const other: [32]u8 = @splat(0x42);
    try rig.tmp.dir.deleteFile(testing.io, "seal.key");
    try files.write_seed(testing.io, rig.tmp.dir, "tmp", "seal.key", other, &rig.diag);

    try testing.expect(try rig.plan(true) == .discard);
    try testing.expectEqual(@as(usize, 1), try rig.count("/edge-certs/"));
    try testing.expectEqual(@as(usize, 1), try rig.count("/acme-orders/"));
    try testing.expectEqualSlices(u8, &other, &(try rig.key_file()).?);

    var fresh = try rig.open_key(true);
    defer fresh.wipe();
    try testing.expectEqual(@as(usize, 0), try rig.count("/edge-certs/"));
    try testing.expectEqual(@as(usize, 0), try rig.count("/acme-orders/"));
    var name: [aside_name_bytes_max]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try rig.asides(&name));
    const aside = name[0 .. "seal.key.discarded-".len + 10];
    const kept = (try files.read_seed(testing.io, rig.tmp.dir, "tmp", aside, &rig.diag)).?;
    try testing.expectEqualSlices(u8, &other, &kept);
    try testing.expect(!std.mem.eql(u8, &other, &fresh.bytes));
}

test "a key written by another start meanwhile is read, never replaced" {
    // Goal: no-replace creation (ruling 4). Method: write the key file between the check and
    // `make`, as a racing start would: `make` returns that key and leaves the file as it was.
    var rig: TestRig = undefined;
    try rig.init(testing.io);
    defer rig.deinit();
    const racer: [32]u8 = @splat(0x17);
    try files.write_seed(testing.io, rig.tmp.dir, "tmp", "seal.key", racer, &rig.diag);
    var key = try make(testing.io, rig.path(), "seal.key", &rig.diag);
    defer key.wipe();
    try testing.expectEqualSlices(u8, &racer, &key.bytes);
    try testing.expectEqualSlices(u8, &racer, &(try rig.key_file()).?);
}

test "a record is checked envelope by envelope, and a clear member naming the magic is none" {
    // Goal: the start check reads every envelope (ruling 3). Method: a record whose first
    // envelope opens and whose second was sealed with another key is refused; a record whose
    // clear member is a host named "zcseal1.example.com" next to a good envelope starts.
    var rig: TestRig = undefined;
    try rig.init(testing.io);
    defer rig.deinit();
    var key = try rig.open_key(false);
    defer key.wipe();
    const other: seal.Key = .{ .bytes = @splat(0x42) };
    var first: [seal.envelope_bytes_max]u8 = undefined;
    var second: [seal.envelope_bytes_max]u8 = undefined;
    const nonce: [seal.nonce_bytes]u8 = @splat(7);
    const path_ = "/acme-account/0123abcd";
    const a = seal.seal(&key, path_, "one", nonce, &first);
    var value: [2 * seal.envelope_bytes_max + 64]u8 = undefined;
    try rig.put(path_, try std.fmt.bufPrint(&value, "{{\"a\":\"{s}\",\"b\":\"{s}\"}}", .{
        a, seal.seal(&other, path_, "two", nonce, &second),
    }));
    try testing.expectError(error.Failed, rig.open_key(false));
    try testing.expectEqual(codes.Code.E0824, rig.diag.code.?);
    try testing.expect(cause_holds(&rig.diag, "sealed with another key"));

    rig.diag.reset();
    try rig.put(path_, try std.fmt.bufPrint(&value, "{{\"host\":\"zcseal1.example.com\"," ++
        "\"key\":\"{s}\"}}", .{a}));
    var ok = try rig.open_key(false);
    ok.wipe();
}

test "the scan's bound is one cause naming the bound, the count and a remedy without the flag" {
    var diag: Diag = undefined;
    diag.reset();
    raise_too_many(&diag, "/edge-certs/");
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const text = diag_mod.render(&diagnostic, .text, false, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, "more than 2048000 records under /edge-certs/") !=
        null);
    try testing.expect(std.mem.indexOf(u8, text, "--discard-sealed") == null);
    diag.reset();
    raise_unfinished(&diag, "/edge-certs/");
    diag_mod.to_diagnostic(&diagnostic, &diag);
    const unfinished = diag_mod.render(&diagnostic, .text, false, &buffer);
    try testing.expectEqual(codes.Code.E0824, diag.code.?);
    try testing.expect(std.mem.indexOf(u8, unfinished, "start once with") == null);
    try testing.expect(std.mem.indexOf(u8, unfinished, "another writer") != null);
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

/// The diagnostic in each mode (text, --verbose, JSON) holds neither the key nor the plaintext.
fn expect_redacted_all(diag: *Diag, key: []const u8, plain: []const u8) !void {
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    inline for (.{ .text, .verbose, .json }) |mode| {
        const text = diag_mod.render(&diagnostic, mode, false, &buffer);
        try redaction.expect_absent(text, key, @tagName(mode));
        try redaction.expect_absent(text, plain, @tagName(mode));
    }
}

fn cause_holds(diag: *Diag, needle: []const u8) bool {
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const text = diag_mod.render(&diagnostic, .verbose, false, &buffer);
    return std.mem.indexOf(u8, text, needle) != null;
}
