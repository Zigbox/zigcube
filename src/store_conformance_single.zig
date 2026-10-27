//! The single-threaded half of the store conformance suite: every test that needs no thread, so
//! it can run anywhere a `Store` can. `zig build test-store` runs it against the chosen backend
//! (through `store_conformance.zig`); `zig build test` and `zig build wasm-test` run it against
//! the memory store, the latter under WASI in Node, which is the environment the browser's
//! store lives in. The rules and the harness are described in `store_harness.zig` and
//! `store_conformance.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const constants = @import("constants.zig");
const codes = @import("diag/codes.zig");
const Diag = @import("diag.zig").Diag;
const store = @import("store.zig");
const harness_mod = @import("store_harness.zig");

const Allocator = std.mem.Allocator;
const Revision = store.Revision;
const Store = store.Store;
const Harness = harness_mod.Harness;
const Connection = harness_mod.Connection;
const connections_max = harness_mod.connections_max;
const watch_polls_max = harness_mod.watch_polls_max;
const model_steps = harness_mod.model_steps;
const model_events_max = harness_mod.model_events_max;
const key_bytes = harness_mod.key_bytes;
const put_one = harness_mod.put_one;
const delete_one = harness_mod.delete_one;
const expect_failure = harness_mod.expect_failure;
const expect_status = harness_mod.expect_status;
const drain = harness_mod.drain;

test "watch: a revision that does not fit the batch is held back whole, never skipped" {
    // Goal: regression for "no gaps" at the batch limit. Method: fill one batch exactly with
    // single-put revisions, then commit a two-event transaction that cannot fit after it. The
    // first batch must stop at the revision before the pair (the bookmark must not jump past
    // what was held back), the second must carry both events of the pair, and together they must
    // deliver every event exactly once, in order.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = (try harness.connect()).interface();
    var name: [16]u8 = undefined;
    for (0..constants.store_watch_batch_max) |index| {
        const key = try std.fmt.bufPrint(&name, "/w/{d:0>4}", .{index});
        _ = try put_one(s, &diag, key, "v");
    }
    const pair = [_]store.Op{
        .{ .put = .{ .key = "/w/last-a", .value = "a" } },
        .{ .put = .{ .key = "/w/last-b", .value = "b" } },
    };
    const head = (try s.txn(.{ .on_success = &pair }, &diag)).revision;

    var watch = try s.watch(.{ .prefix = "/w/", .from_revision = 1 }, &diag);
    defer watch.close();
    const first = try watch.next(arena_state.allocator(), 0, &diag);
    try testing.expectEqual(@as(usize, constants.store_watch_batch_max), first.events.len);
    try testing.expectEqual(head - 1, first.revision);
    const second = try watch.next(arena_state.allocator(), 0, &diag);
    try testing.expectEqual(@as(usize, 2), second.events.len);
    try testing.expectEqual(head, second.events[0].kv.mod_revision);
    try testing.expectEqual(head, second.events[1].kv.mod_revision);
    try testing.expectEqual(head, second.revision);
    const idle = try watch.next(arena_state.allocator(), 0, &diag);
    try testing.expectEqual(@as(usize, 0), idle.events.len);
    try testing.expectEqual(head, idle.revision);
}

// ---- Revisions ------------------------------------------------------------------------------

test "txn: a transaction that changes nothing takes no revision, even on an empty store" {
    // Goal: regression for a wrong postcondition in `Store.txn` that the seeded model test found
    // (seed 34 on SQLite): it asserted that a transaction with operations returns a revision above
    // zero, but deleting an absent key on an empty store changes nothing, so the revision is
    // the current one, 0. Method: each way of changing nothing, first on the empty store and
    // then on a store with one key; the revision must not move and the key must be as it was.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const s = (try harness.connect()).interface();
    const absent = try s.txn(.{ .on_success = &.{.{ .delete = "/absent" }} }, &diag);
    try testing.expect(absent.succeeded);
    try testing.expectEqual(@as(Revision, 0), absent.revision);
    const empty = try s.txn(.{}, &diag);
    try testing.expectEqual(@as(Revision, 0), empty.revision);
    try expect_status(s, &diag, 0, 0);

    _ = try put_one(s, &diag, "/k", "v");
    const lost = try s.txn(.{
        .compares = &.{.{ .key = "/k", .mod_revision = 0 }},
        .on_success = &.{.{ .put = .{ .key = "/k", .value = "no" } }},
    }, &diag);
    try testing.expect(!lost.succeeded);
    try testing.expectEqual(@as(Revision, 1), lost.revision);
    try testing.expectEqual(@as(Revision, 1), (try delete_one(s, &diag, "/absent")));
    try expect_status(s, &diag, 1, 0);
}

// ---- Resume, compaction, leases ----------------------------------------------------------------

test "watch: after a reconnect, resuming from bookmark + 1 sees exactly what is new" {
    // Goal: a watcher that loses its connection loses nothing. Method: a reader on one
    // connection watches and reads, including a write outside its prefix that moves only the
    // bookmark; it closes; a writer on another connection changes things; a reader on a third
    // connection resumes from the old bookmark + 1 and must see precisely the new events, once,
    // in order. Then it resumes at head + 1 (nothing yet), sees the next write arrive, and
    // is refused a start beyond head + 1.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const writer = (try harness.connect()).interface();
    _ = try put_one(writer, &diag, "/r/a", "1");
    _ = try put_one(writer, &diag, "/x/ignored", "2");
    _ = try put_one(writer, &diag, "/r/b", "3");

    var first = try (try harness.connect()).interface().watch(
        .{ .prefix = "/r/", .from_revision = 1 },
        &diag,
    );
    const batch = try first.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 2), batch.events.len);
    try testing.expectEqual(@as(Revision, 3), batch.revision);
    _ = try put_one(writer, &diag, "/x/c", "4"); // Outside the prefix: only the bookmark moves.
    const idle = try first.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 0), idle.events.len);
    try testing.expectEqual(@as(Revision, 4), idle.revision);
    first.close();

    _ = try put_one(writer, &diag, "/r/c", "5");
    _ = try delete_one(writer, &diag, "/r/a");
    var again = try (try harness.connect()).interface().watch(
        .{ .prefix = "/r/", .from_revision = idle.revision + 1 },
        &diag,
    );
    const resumed = try again.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 2), resumed.events.len);
    try testing.expectEqualStrings("/r/c", resumed.events[0].kv.key);
    try testing.expectEqual(@as(Revision, 5), resumed.events[0].kv.mod_revision);
    try testing.expectEqual(store.EventKind.delete, resumed.events[1].kind);
    try testing.expectEqual(@as(Revision, 6), resumed.events[1].kv.mod_revision);
    try testing.expectEqual(@as(usize, 0), resumed.events[1].kv.value.len);
    try testing.expectEqual(@as(Revision, 6), resumed.revision);
    again.close();

    var tail = try writer.watch(.{ .prefix = "/r/", .from_revision = 7 }, &diag);
    defer tail.close();
    try testing.expectEqual(@as(usize, 0), (try tail.next(arena, 0, &diag)).events.len);
    _ = try put_one(writer, &diag, "/r/d", "6");
    const late = try tail.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 1), late.events.len);
    try testing.expectEqual(@as(Revision, 7), late.events[0].kv.mod_revision);
    try expect_failure(&diag, error.FutureRevision, writer.watch(
        .{ .prefix = "/r/", .from_revision = 9 },
        &diag,
    ), .E0204);
}

test "compaction: a delete pruned across batches never brings its key back" {
    // Goal: compaction prunes oldest first, so a tombstone is never removed while an older put
    // of its key survives; that put would no longer be superseded by anything at or below the
    // point and would read as live for ever. Method: put /k, then enough puts of a filler key
    // that pruning takes more than one batch, delete /k, compact past everything, and check
    // that /k is absent from historical reads at the point and from a list there.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = (try harness.connect()).interface();
    _ = try put_one(s, &diag, "/k", "doomed");
    const batch_rows = constants.store_compact_batch_rows;
    const filler_count = batch_rows + @divFloor(batch_rows, 5); // More than one batch to prune.
    for (0..filler_count) |_| _ = try put_one(s, &diag, "/filler", "x");
    const deleted = try delete_one(s, &diag, "/k");
    const head = try put_one(s, &diag, "/filler", "last");
    try s.compact(head, &diag);
    try expect_status(s, &diag, head, head);
    try testing.expect((try s.get(arena, "/k", head, &diag)).kv == null);
    try testing.expect((try s.get(arena, "/k", null, &diag)).kv == null);
    const listed = try s.list(arena, .{ .prefix = "/", .at_revision = head, .limit = 10 }, &diag);
    try testing.expectEqual(@as(usize, 1), listed.kvs.len);
    try testing.expectEqualStrings("/filler", listed.kvs[0].key);
    try testing.expect(deleted < head);
}

test "compaction: reads and watches below the point fail explicitly; at and above it work" {
    // Goal: "compacted" is an error, never silence, and compaction keeps every state a reader
    // at or after the point can ask for. Method: build history with a delete and a re-create,
    // record the state at revision 3, open watches before and after the point, compact to 3,
    // and check reads below, at and above it, the two watches, a new watch, and the bounds
    // of `compact` itself.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = (try harness.connect()).interface();
    _ = try put_one(s, &diag, "/k", "one"); // 1
    _ = try put_one(s, &diag, "/k", "two"); // 2
    _ = try put_one(s, &diag, "/other", "x"); // 3
    _ = try delete_one(s, &diag, "/k"); // 4
    _ = try put_one(s, &diag, "/k", "three"); // 5
    const before = try s.list(arena, .{ .prefix = "/", .at_revision = 3, .limit = 10 }, &diag);
    try testing.expectEqual(@as(usize, 2), before.kvs.len);

    var behind = try s.watch(.{ .prefix = "/", .from_revision = 2 }, &diag);
    defer behind.close();
    var ahead = try s.watch(.{ .prefix = "/", .from_revision = 5 }, &diag);
    defer ahead.close();
    try s.compact(3, &diag);
    try expect_status(s, &diag, 5, 3);

    try expect_failure(&diag, error.Compacted, s.get(arena, "/k", 2, &diag), .E0203);
    const old_list: store.ListOptions = .{ .prefix = "/", .at_revision = 2, .limit = 10 };
    try expect_failure(&diag, error.Compacted, s.list(arena, old_list, &diag), .E0203);
    const at_point = try s.list(arena, .{ .prefix = "/", .at_revision = 3, .limit = 10 }, &diag);
    try testing.expectEqual(before.kvs.len, at_point.kvs.len);
    for (before.kvs, at_point.kvs) |was, now| {
        try testing.expectEqualStrings(was.key, now.key);
        try testing.expectEqualStrings(was.value, now.value);
        try testing.expectEqual(was.mod_revision, now.mod_revision);
    }
    try testing.expect((try s.get(arena, "/k", 4, &diag)).kv == null);
    try testing.expectEqualStrings("three", (try s.get(arena, "/k", 5, &diag)).kv.?.value);
    try expect_failure(&diag, error.FutureRevision, s.get(arena, "/k", 6, &diag), .E0204);

    try expect_failure(&diag, error.Compacted, behind.next(arena, 0, &diag), .E0203);
    const kept = try ahead.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 1), kept.events.len);
    try testing.expectEqual(@as(Revision, 5), kept.events[0].kv.mod_revision);
    const stale: store.WatchOptions = .{ .prefix = "/", .from_revision = 3 };
    try expect_failure(&diag, error.Compacted, s.watch(stale, &diag), .E0203);
    var fresh = try s.watch(.{ .prefix = "/", .from_revision = 4 }, &diag);
    fresh.close();

    try s.compact(2, &diag); // Below the point: nothing to do, and not an error.
    try expect_status(s, &diag, 5, 3);
    try expect_failure(&diag, error.FutureRevision, s.compact(9, &diag), .E0204);
    try s.compact(5, &diag);
    try expect_failure(&diag, error.Compacted, s.get(arena, "/k", 4, &diag), .E0203);
    try testing.expectEqualStrings("three", (try s.get(arena, "/k", 5, &diag)).kv.?.value);
}

test "lease: expiry deletes its keys under one revision, visible to a watcher elsewhere" {
    // Goal: lease expiry as the server will use it. Method: one connection grants a lease and
    // attaches two keys (and one unattached key), renews it once, and lets it lapse on the
    // manual clock; a watch on a second connection and `expire_leases` on a third must see both
    // keys deleted under a single revision, a late keepalive must fail, and expiring again must
    // do nothing and take no revision.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const owner = (try harness.connect()).interface();
    const lease = try owner.lease_grant(1000, &diag);
    const ops = [_]store.Op{
        .{ .put = .{ .key = "/nodes/n2", .value = "b", .lease = lease.id } },
        .{ .put = .{ .key = "/nodes/n1", .value = "a", .lease = lease.id } },
        .{ .put = .{ .key = "/services/s", .value = "kept" } },
    };
    const written = try owner.txn(.{ .on_success = &ops }, &diag);

    harness.manual.advance(900);
    try testing.expectEqual(lease.id, (try owner.lease_keepalive(lease.id, &diag)).id);
    harness.manual.advance(900); // 1800: past the original deadline, inside the renewed one.
    const reaper = (try harness.connect()).interface();
    try testing.expectEqual(@as(u32, 0), try reaper.expire_leases(&diag));

    const watcher = (try harness.connect()).interface();
    var watch = try watcher.watch(
        .{ .prefix = "/nodes/", .from_revision = written.revision + 1 },
        &diag,
    );
    defer watch.close();
    harness.manual.advance(200);
    try expect_failure(&diag, error.LeaseNotFound, owner.lease_keepalive(lease.id, &diag), .E0205);
    try testing.expectEqual(@as(u32, 1), try reaper.expire_leases(&diag));

    const batch = try watch.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 2), batch.events.len);
    try testing.expectEqual(store.EventKind.delete, batch.events[0].kind);
    try testing.expectEqualStrings("/nodes/n1", batch.events[0].kv.key);
    try testing.expectEqualStrings("/nodes/n2", batch.events[1].kv.key);
    try testing.expectEqual(written.revision + 1, batch.events[0].kv.mod_revision);
    try testing.expectEqual(batch.events[0].kv.mod_revision, batch.events[1].kv.mod_revision);
    try testing.expect((try owner.get(arena, "/services/s", null, &diag)).kv != null);
    try testing.expectEqual(@as(u32, 0), try reaper.expire_leases(&diag));
    try expect_status(owner, &diag, written.revision + 1, 0);
}

test "lease: revoke frees its keys in one revision and reports it; unknown leases are refused" {
    // Goal: revoke's contract. Method: revoke a lease with keys (the returned revision is that of
    // the deletion), revoke one that holds no key (the current revision, no new one), then
    // revoke the first again (unknown) and an id never granted.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const s = (try harness.connect()).interface();
    const lease = try s.lease_grant(5000, &diag);
    const attach: store.Op = .{ .put = .{ .key = "/n", .value = "v", .lease = lease.id } };
    _ = try s.txn(.{ .on_success = &.{attach} }, &diag);
    try testing.expectEqual(@as(Revision, 2), try s.lease_revoke(lease.id, &diag));
    try expect_failure(&diag, error.LeaseNotFound, s.lease_revoke(lease.id, &diag), .E0205);
    const empty = try s.lease_grant(5000, &diag);
    try testing.expectEqual(@as(Revision, 2), try s.lease_revoke(empty.id, &diag));
    try expect_failure(&diag, error.LeaseNotFound, s.lease_revoke(777_777, &diag), .E0205);
    try expect_status(s, &diag, 2, 0);
}

test "lease: a put that names a dead lease changes nothing" {
    // Goal: a transaction is all or nothing even when the refusal comes late. Method: for a lease
    // that was never granted, one that ran out but was not yet reaped, and one that was
    // revoked, submit a transaction whose first op is fine and whose second names the lease.
    // It must fail with ZC-E0205 and leave no trace: no revision, no first key. A dead lease
    // named only by the branch not taken is no problem.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = (try harness.connect()).interface();
    const lapsed = try s.lease_grant(1000, &diag);
    const revoked = try s.lease_grant(1000, &diag);
    _ = try s.lease_revoke(revoked.id, &diag);
    harness.manual.advance(1500);
    for ([_]store.LeaseId{ 777_777, lapsed.id, revoked.id }) |dead| {
        const ops = [_]store.Op{
            .{ .put = .{ .key = "/a", .value = "1" } },
            .{ .put = .{ .key = "/b", .value = "2", .lease = dead } },
        };
        const refused = s.txn(.{ .on_success = &ops }, &diag);
        try expect_failure(&diag, error.LeaseNotFound, refused, .E0205);
        try expect_status(s, &diag, 0, 0);
        try testing.expect((try s.get(arena_state.allocator(), "/a", null, &diag)).kv == null);
    }
    const untaken = try s.txn(.{
        .compares = &.{.{ .key = "/a", .mod_revision = 0 }},
        .on_success = &.{.{ .put = .{ .key = "/a", .value = "1" } }},
        .on_failure = &.{.{ .put = .{ .key = "/b", .value = "2", .lease = lapsed.id } }},
    }, &diag);
    try testing.expect(untaken.succeeded);
    try expect_status(s, &diag, 1, 0);
}

test "lease: one lease holds at most the limit of keys, and a refusal changes nothing" {
    // Goal: the bound that lets a revoke fit in one watch batch. Method: fill a lease to its
    // limit in transactions of at most the per-branch limit, then try one more key.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const s = (try harness.connect()).interface();
    const lease = try s.lease_grant(60_000, &diag);
    var name: [16]u8 = undefined;
    var attached: u32 = 0;
    while (attached < constants.store_lease_keys_max) : (attached += 1) {
        const key = try std.fmt.bufPrint(&name, "/l/{d:0>3}", .{attached});
        const op: store.Op = .{ .put = .{ .key = key, .value = "v", .lease = lease.id } };
        _ = try s.txn(.{ .on_success = &.{op} }, &diag);
    }
    const head = (try s.status(&diag)).revision;
    const extra: store.Op = .{ .put = .{ .key = "/l/extra", .value = "v", .lease = lease.id } };
    try expect_failure(&diag, error.NoCapacity, s.txn(.{ .on_success = &.{extra} }, &diag), .E0207);
    try expect_status(s, &diag, head, 0);
    const again: store.Op = .{ .put = .{ .key = "/l/000", .value = "w", .lease = lease.id } };
    _ = try s.txn(.{ .on_success = &.{again} }, &diag); // Updating a key it holds is fine.
}

test "lease: moving a key onto a full lease is refused; moving one off it makes room" {
    // Goal: the key limit counts the keys a lease would hold after the transaction, not just the
    // keys that are new. A revoke deletes all of them in one watch batch, so a lease over the
    // limit would break that. Method: fill one lease to the limit and give another lease a
    // key; putting the other lease's key onto the full lease must be refused with nothing
    // changed. Then, in a single transaction, move one of the full lease's keys to the other
    // lease and attach the key that was refused; that leaves the count unchanged, so it works.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const s = (try harness.connect()).interface();
    const full = try s.lease_grant(60_000, &diag);
    const other = try s.lease_grant(60_000, &diag);
    var name: [16]u8 = undefined;
    for (0..constants.store_lease_keys_max) |index| {
        const key = try std.fmt.bufPrint(&name, "/l/{d:0>3}", .{index});
        const op: store.Op = .{ .put = .{ .key = key, .value = "v", .lease = full.id } };
        _ = try s.txn(.{ .on_success = &.{op} }, &diag);
    }
    const theirs: store.Op = .{ .put = .{ .key = "/o/key", .value = "v", .lease = other.id } };
    _ = try s.txn(.{ .on_success = &.{theirs} }, &diag);
    const head = (try s.status(&diag)).revision;

    const steal: store.Op = .{ .put = .{ .key = "/o/key", .value = "v", .lease = full.id } };
    try expect_failure(&diag, error.NoCapacity, s.txn(.{ .on_success = &.{steal} }, &diag), .E0207);
    try expect_status(s, &diag, head, 0);

    const swap = [_]store.Op{
        .{ .put = .{ .key = "/l/000", .value = "v", .lease = other.id } },
        steal,
    };
    const swapped = try s.txn(.{ .on_success = &swap }, &diag);
    try testing.expectEqual(head + 1, swapped.revision);
    try testing.expectEqual(head + 2, try s.lease_revoke(full.id, &diag));
}

test "limits: oversized requests are refused with a code and write nothing" {
    // Goal: the negative space of the size bounds, through the interface. Method: a value one
    // byte over the limit, a branch one operation over, and a ttl outside its range.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const s = (try harness.connect()).interface();
    const big = try testing.allocator.alloc(u8, constants.store_value_bytes_max + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const too_big: store.Op = .{ .put = .{ .key = "/big", .value = big } };
    try expect_failure(&diag, error.TooLarge, s.txn(.{ .on_success = &.{too_big} }, &diag), .E0206);

    var many: [constants.store_txn_ops_max + 1]store.Op = undefined;
    var names: [many.len][8]u8 = undefined;
    for (&many, &names, 0..) |*op, *name, index| {
        op.* = .{ .delete = try std.fmt.bufPrint(name, "/k{d:0>4}", .{index}) };
    }
    try expect_failure(&diag, error.TooLarge, s.txn(.{ .on_success = &many }, &diag), .E0206);
    try expect_failure(&diag, error.TooLarge, s.lease_grant(1, &diag), .E0206);
    try expect_status(s, &diag, 0, 0);
}

// ---- Pagination ------------------------------------------------------------------------------

test "list: pages are consistent at one revision, ordered bytewise, and join with no gap" {
    // Goal: pagination with at_revision. Method: write keys out of order (and one outside the
    // prefix), read page one, change the store (inside the prefix: an insert and a delete), then
    // read the rest at the first page's revision: the later changes must not appear and the pages
    // must join up with no repeat and no gap.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = (try harness.connect()).interface();
    for ([_][]const u8{ "/r/e", "/r/b", "/r/d", "/r/a", "/r/c", "/other/x" }) |key| {
        _ = try put_one(s, &diag, key, "v");
    }
    const page1 = try s.list(arena, .{ .prefix = "/r/", .limit = 2 }, &diag);
    try testing.expectEqual(@as(usize, 2), page1.kvs.len);
    try testing.expectEqualStrings("/r/a", page1.kvs[0].key);
    try testing.expectEqualStrings("/r/b", page1.kvs[1].key);
    try testing.expectEqualStrings("/r/b", page1.continue_after.?);

    _ = try put_one(s, &diag, "/r/bb", "late");
    _ = try delete_one(s, &diag, "/r/d");

    const page2 = try s.list(arena, .{
        .prefix = "/r/",
        .limit = 10,
        .at_revision = page1.revision,
        .continue_after = page1.continue_after,
    }, &diag);
    try testing.expectEqual(@as(usize, 3), page2.kvs.len);
    try testing.expectEqualStrings("/r/c", page2.kvs[0].key);
    try testing.expectEqualStrings("/r/d", page2.kvs[1].key);
    try testing.expectEqualStrings("/r/e", page2.kvs[2].key);
    try testing.expect(page2.continue_after == null);
    const now = try s.list(arena, .{ .prefix = "/r/", .limit = 10 }, &diag);
    try testing.expectEqual(@as(usize, 5), now.kvs.len); // a, b, bb, c, e.
}

test "list: reverse is the ascending list backwards, and its pages join with no gap" {
    // Goal: `reverse` (newest key first) for the current state, a historical read and a prefix.
    // Method: write keys out of order plus one outside the prefix; read all of them reversed and
    // compare with the ascending read; page through two at a time with `continue_after`; then
    // change the store and read the rest of the pages at the first page's revision, which must
    // not show the change.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = (try harness.connect()).interface();
    const keys = [_][]const u8{ "/q/03", "/q/05", "/q/01", "/q/04", "/q/02", "/other/x" };
    for (keys) |key| _ = try put_one(s, &diag, key, "v");

    const ascending = try s.list(arena, .{ .prefix = "/q/", .limit = 10 }, &diag);
    const descending = try s.list(arena, .{ .prefix = "/q/", .limit = 10, .reverse = true }, &diag);
    try testing.expectEqual(@as(usize, 5), descending.kvs.len);
    for (ascending.kvs, 0..) |kv, index| {
        const mirror = descending.kvs[descending.kvs.len - 1 - index];
        try testing.expectEqualStrings(kv.key, mirror.key);
        try testing.expectEqual(kv.mod_revision, mirror.mod_revision);
    }
    try testing.expect(descending.continue_after == null);

    const page1 = try s.list(arena, .{ .prefix = "/q/", .limit = 2, .reverse = true }, &diag);
    try testing.expectEqual(@as(usize, 2), page1.kvs.len);
    try testing.expectEqualStrings("/q/05", page1.kvs[0].key);
    try testing.expectEqualStrings("/q/04", page1.kvs[1].key);
    try testing.expectEqualStrings("/q/04", page1.continue_after.?);

    _ = try put_one(s, &diag, "/q/035", "late");
    _ = try delete_one(s, &diag, "/q/02");

    const rest = try s.list(arena, .{
        .prefix = "/q/",
        .limit = 10,
        .reverse = true,
        .at_revision = page1.revision,
        .continue_after = page1.continue_after,
    }, &diag);
    try testing.expectEqual(@as(usize, 3), rest.kvs.len);
    try testing.expectEqualStrings("/q/03", rest.kvs[0].key);
    try testing.expectEqualStrings("/q/02", rest.kvs[1].key);
    try testing.expectEqualStrings("/q/01", rest.kvs[2].key);
    try testing.expect(rest.continue_after == null);

    const now = try s.list(arena, .{ .prefix = "/q/", .limit = 3, .reverse = true }, &diag);
    try testing.expectEqualStrings("/q/05", now.kvs[0].key);
    try testing.expectEqualStrings("/q/04", now.kvs[1].key);
    try testing.expectEqualStrings("/q/035", now.kvs[2].key);
    try testing.expectEqualStrings("/q/035", now.continue_after.?);
}

test "list: a reverse page ends at the byte limit, and the next one resumes below it" {
    // Goal: the page byte bound holds for a reverse read, counted from the newest key. Method:
    // write values that together exceed `store_page_bytes_max`, read reversed with a limit that
    // would take them all, and join the pages: every key once, in descending order.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = (try harness.connect()).interface();
    const value = try arena.alloc(u8, constants.store_value_bytes_max);
    @memset(value, 'v');
    const count = constants.store_page_bytes_max / constants.store_value_bytes_max + 2;
    var key_buffer: [16]u8 = undefined;
    for (0..count) |index| {
        const key = try std.fmt.bufPrint(&key_buffer, "/big/{d:0>3}", .{index});
        _ = try put_one(s, &diag, key, value);
    }
    var seen: u32 = 0;
    var after: ?[]const u8 = null;
    var pinned: ?Revision = null;
    var previous: []const u8 = "/big/~";
    for (0..count) |_| {
        const page = try s.list(arena, .{
            .prefix = "/big/",
            .limit = constants.store_list_limit_max,
            .reverse = true,
            .at_revision = pinned,
            .continue_after = after,
        }, &diag);
        try testing.expect(page.kvs.len > 0);
        try testing.expect(page.kvs.len < count); // The byte limit cut the first page short.
        for (page.kvs) |kv| {
            try testing.expectEqual(std.math.Order.gt, std.mem.order(u8, previous, kv.key));
            previous = kv.key;
            seen += 1;
        }
        after = page.continue_after;
        pinned = page.revision;
        if (after == null) break;
    }
    try testing.expectEqual(@as(u32, count), seen);
}

test "lease_list: id, ttl, remaining time and keys of every lease, read-only" {
    // Goal: the view the Nodes screen needs. Method: grant three leases with different ttls,
    // attach keys to two of them (in an order that is not key order), advance the manual clock,
    // renew one, and read the list at each step; a lapsed but unreaped lease shows 0 remaining
    // and its keys, and a reaped one is gone. Reading takes no revision.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = (try harness.connect()).interface();
    try testing.expectEqual(@as(usize, 0), (try s.lease_list(arena, &diag)).len);

    const first = try s.lease_grant(1000, &diag);
    const second = try s.lease_grant(5000, &diag);
    const third = try s.lease_grant(2000, &diag);
    const ops = [_]store.Op{
        .{ .put = .{ .key = "/nodes/b", .value = "b", .lease = first.id } },
        .{ .put = .{ .key = "/nodes/a", .value = "a", .lease = first.id } },
        .{ .put = .{ .key = "/nodes/c", .value = "c", .lease = third.id } },
        .{ .put = .{ .key = "/plain", .value = "p" } },
    };
    const written = try s.txn(.{ .on_success = &ops }, &diag);

    harness.manual.advance(400);
    const listed = try s.lease_list(arena, &diag);
    try testing.expectEqual(@as(usize, 3), listed.len);
    try testing.expectEqual(first.id, listed[0].id);
    try testing.expectEqual(@as(u32, 1000), listed[0].ttl_ms);
    try testing.expectEqual(@as(u32, 600), listed[0].remaining_ms);
    try testing.expectEqual(@as(usize, 2), listed[0].keys.len);
    try testing.expectEqualStrings("/nodes/a", listed[0].keys[0]);
    try testing.expectEqualStrings("/nodes/b", listed[0].keys[1]);
    try testing.expectEqual(second.id, listed[1].id);
    try testing.expectEqual(@as(u32, 4600), listed[1].remaining_ms);
    try testing.expectEqual(@as(usize, 0), listed[1].keys.len);
    try testing.expectEqual(third.id, listed[2].id);
    try testing.expectEqual(@as(usize, 1), listed[2].keys.len);
    try testing.expectEqualStrings("/nodes/c", listed[2].keys[0]);
    try expect_status(s, &diag, written.revision, 0);

    // Past the first lease's time but not yet reaped: nothing remains, the keys are still there.
    harness.manual.advance(700);
    _ = try s.lease_keepalive(second.id, &diag);
    const lapsed = try s.lease_list(arena, &diag);
    try testing.expectEqual(@as(usize, 3), lapsed.len);
    try testing.expectEqual(@as(u32, 0), lapsed[0].remaining_ms);
    try testing.expectEqual(@as(usize, 2), lapsed[0].keys.len);
    try testing.expectEqual(@as(u32, 5000), lapsed[1].remaining_ms);
    try testing.expectEqual(@as(u32, 900), lapsed[2].remaining_ms);

    try testing.expectEqual(@as(u32, 1), try s.expire_leases(&diag));
    const reaped = try s.lease_list(arena, &diag);
    try testing.expectEqual(@as(usize, 2), reaped.len);
    try testing.expectEqual(second.id, reaped[0].id);
    try testing.expectEqual(third.id, reaped[1].id);
}

test "lease_list: a lease at the key limit lists them all, in order" {
    // Goal: the bound of the view. Method: attach `store_lease_keys_max` keys to one lease, in
    // descending order of key, and read them back ascending.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = (try harness.connect()).interface();
    const lease = try s.lease_grant(5000, &diag);
    var names: [constants.store_lease_keys_max][8]u8 = undefined;
    var ops: [constants.store_lease_keys_max]store.Op = undefined;
    comptime assert(constants.store_lease_keys_max % constants.store_txn_ops_max == 0);
    for (&names, &ops, 0..) |*name, *op, index| {
        const number: u32 = @intCast(constants.store_lease_keys_max - 1 - index);
        const text = try std.fmt.bufPrint(name, "/l/{d:0>3}", .{number});
        op.* = .{ .put = .{ .key = text, .value = "v", .lease = lease.id } };
    }
    const chunk = constants.store_txn_ops_max; // A transaction is small; the lease is not.
    var done: usize = 0;
    while (done < ops.len) : (done += chunk) {
        _ = try s.txn(.{ .on_success = ops[done..][0..chunk] }, &diag);
    }
    const listed = try s.lease_list(arena, &diag);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqual(@as(usize, constants.store_lease_keys_max), listed[0].keys.len);
    for (listed[0].keys, 0..) |key, index| {
        var expected: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&expected, "/l/{d:0>3}", .{index});
        try testing.expectEqualStrings(text, key);
    }
}

// ---- A model to compare against ----------------------------------------------------------------

const model_keys = [_][]const u8{ "/m/x/a", "/m/x/b", "/m/x/c", "/m/y/a", "/m/y/b", "/m/z" };
const model_prefixes = [_][]const u8{ "/m/", "/m/x/", "/m/y/", "/m/z", "/m/x/b", "" };
/// The key a compare-and-swap writes when its compare fails.
const audit_key: u8 = 5;
const pages_max = 64;

const ModelEvent = struct {
    revision: Revision,
    key: u8,
    kind: store.EventKind,
    value: [12]u8,
    value_len: u8,
    create_revision: Revision,

    fn value_slice(event: *const ModelEvent) []const u8 {
        return event.value[0..event.value_len];
    }
};

/// What one op of a model transaction does.
const Change = struct {
    key: u8,
    delete: bool,
    value: [12]u8 = undefined,
    value_len: u8 = 0,
};

/// The whole history, kept forever: the store forgets below its compaction point, the model does
/// not, so it can say what any reachable revision must look like.
const Model = struct {
    events: [model_events_max]ModelEvent = undefined,
    count: u32 = 0,
    head: Revision = 0,
    compacted: Revision = 0,
    counter: u32 = 0,

    /// The key as it was at `revision`: its last event then, if that was a put.
    fn state(model: *const Model, key: u8, revision: Revision) ?*const ModelEvent {
        var found: ?*const ModelEvent = null;
        for (model.events[0..model.count]) |*event| {
            if (event.revision > revision) break;
            if (event.key == key) found = event;
        }
        const event = found orelse return null;
        return if (event.kind == .put) event else null;
    }

    fn fresh_value(model: *Model, change: *Change) void {
        model.counter += 1;
        // Cannot fail: "v" and a u32 are at most 11 bytes, and the buffer holds 12.
        const text = std.fmt.bufPrint(&change.value, "v{d}", .{model.counter}) catch unreachable;
        change.value_len = @intCast(text.len);
    }

    /// Applies one transaction: a put always writes, a delete only if the key exists. One
    /// revision if anything was written, none otherwise.
    fn apply(model: *Model, changes: []const Change) void {
        const revision = model.head + 1;
        var wrote = false;
        for (changes) |change| {
            const live = model.state(change.key, model.head);
            if (change.delete and live == null) continue;
            assert(model.count < model.events.len);
            model.events[model.count] = .{
                .revision = revision,
                .key = change.key,
                .kind = if (change.delete) .delete else .put,
                .value = change.value,
                .value_len = if (change.delete) 0 else change.value_len,
                .create_revision = if (live) |l| l.create_revision else revision,
            };
            model.count += 1;
            wrote = true;
        }
        if (wrote) model.head = revision;
    }
};

fn build_ops(changes: []const Change, ops: *[3]store.Op) void {
    assert(changes.len <= ops.len);
    for (changes, 0..) |*change, index| {
        ops[index] = if (change.delete)
            .{ .delete = model_keys[change.key] }
        else
            .{ .put = .{
                .key = model_keys[change.key],
                .value = change.value[0..change.value_len],
            } };
    }
}

fn expect_kv(got: ?store.KeyValue, want: ?*const ModelEvent) !void {
    const event = want orelse {
        try testing.expect(got == null);
        return;
    };
    const kv = got.?;
    try testing.expectEqualStrings(model_keys[event.key], kv.key);
    try testing.expectEqualStrings(event.value_slice(), kv.value);
    try testing.expectEqual(event.create_revision, kv.create_revision);
    try testing.expectEqual(event.revision, kv.mod_revision);
    try testing.expectEqual(store.lease_none, kv.lease);
}

const ModelRun = struct {
    s: Store,
    model: Model = .{},
    prng: std.Random.DefaultPrng,
    diag: Diag = undefined,
    arena_state: std.heap.ArenaAllocator,

    fn arena(run: *ModelRun) Allocator {
        return run.arena_state.allocator();
    }

    fn check_status(run: *ModelRun) !void {
        try expect_status(run.s, &run.diag, run.model.head, run.model.compacted);
    }

    /// A revision a read may ask for: from the compaction point to the head.
    fn readable_revision(run: *ModelRun) Revision {
        const span = run.model.head - run.model.compacted + 1;
        return run.model.compacted + run.prng.random().uintLessThan(u64, span);
    }

    fn step_write(run: *ModelRun) !void {
        const random = run.prng.random();
        var changes: [3]Change = undefined;
        const count = random.intRangeAtMost(u32, 1, 3);
        const start = random.uintLessThan(u32, model_keys.len);
        for (changes[0..count], 0..) |*change, index| {
            const key: u8 = @intCast((start + index) % model_keys.len);
            change.* = .{ .key = key, .delete = random.uintLessThan(u32, 4) == 0 };
            if (!change.delete) run.model.fresh_value(change);
        }
        var ops: [3]store.Op = undefined;
        build_ops(changes[0..count], &ops);
        const result = try run.s.txn(.{ .on_success = ops[0..count] }, &run.diag);
        run.model.apply(changes[0..count]);
        try testing.expect(result.succeeded);
        try testing.expectEqual(run.model.head, result.revision);
    }

    fn step_cas(run: *ModelRun) !void {
        const random = run.prng.random();
        const key: u8 = @intCast(random.uintLessThan(u32, model_keys.len));
        const live = run.model.state(key, run.model.head);
        const actual: Revision = if (live) |l| l.revision else 0;
        const holds = random.uintLessThan(u32, 3) != 0;
        const expected = if (holds) actual else actual + 1; // A revision it cannot have.
        var success = [1]Change{.{ .key = key, .delete = false }};
        var failure = [1]Change{.{ .key = audit_key, .delete = false }};
        run.model.fresh_value(&success[0]);
        run.model.fresh_value(&failure[0]);
        var success_ops: [3]store.Op = undefined;
        var failure_ops: [3]store.Op = undefined;
        build_ops(&success, &success_ops);
        build_ops(&failure, &failure_ops);
        const result = try run.s.txn(.{
            .compares = &.{.{ .key = model_keys[key], .mod_revision = expected }},
            .on_success = success_ops[0..1],
            .on_failure = failure_ops[0..1],
        }, &run.diag);
        run.model.apply(if (holds) &success else &failure);
        try testing.expectEqual(holds, result.succeeded);
        try testing.expectEqual(run.model.head, result.revision);
    }

    fn step_get(run: *ModelRun) !void {
        const random = run.prng.random();
        const key: u8 = @intCast(random.uintLessThan(u32, model_keys.len));
        const model = &run.model;
        switch (random.uintLessThan(u32, 6)) {
            0 => {
                const got = try run.s.get(run.arena(), model_keys[key], null, &run.diag);
                try expect_kv(got.kv, model.state(key, model.head));
            },
            1 => if (model.compacted > 0) {
                const old = random.uintLessThan(u64, model.compacted);
                const got = run.s.get(run.arena(), model_keys[key], old, &run.diag);
                try expect_failure(&run.diag, error.Compacted, got, .E0203);
            },
            2 => {
                const future = model.head + 1 + random.uintLessThan(u64, 3);
                const got = run.s.get(run.arena(), model_keys[key], future, &run.diag);
                try expect_failure(&run.diag, error.FutureRevision, got, .E0204);
            },
            else => {
                const revision = run.readable_revision();
                const got = try run.s.get(run.arena(), model_keys[key], revision, &run.diag);
                try testing.expectEqual(revision, got.revision);
                try expect_kv(got.kv, model.state(key, revision));
            },
        }
    }

    fn step_list(run: *ModelRun) !void {
        const random = run.prng.random();
        const prefix = model_prefixes[random.uintLessThan(u32, model_prefixes.len)];
        const limit = random.intRangeAtMost(u32, 1, 4);
        var revision: ?Revision = if (random.boolean()) null else run.readable_revision();
        var after: ?[]const u8 = null;
        var got: std.ArrayList(store.KeyValue) = .empty;
        var finished = false;
        for (0..pages_max) |_| {
            const page = try run.s.list(run.arena(), .{
                .prefix = prefix,
                .at_revision = revision,
                .limit = limit,
                .continue_after = after,
            }, &run.diag);
            try testing.expect(page.kvs.len <= limit);
            revision = page.revision; // Later pages are read at the first page's revision.
            try got.appendSlice(run.arena(), page.kvs);
            after = page.continue_after;
            if (after == null) {
                finished = true;
                break;
            }
        }
        try testing.expect(finished);
        try run.expect_listing(prefix, revision.?, got.items);
    }

    fn expect_listing(
        run: *ModelRun,
        prefix: []const u8,
        revision: Revision,
        got: []const store.KeyValue,
    ) !void {
        var index: usize = 0;
        for (model_keys, 0..) |name, key| {
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            const want = run.model.state(@intCast(key), revision) orelse continue;
            try testing.expect(index < got.len);
            try expect_kv(got[index], want);
            index += 1;
        }
        try testing.expectEqual(got.len, index);
    }

    fn step_compact(run: *ModelRun) !void {
        if (run.model.head == 0) return;
        const revision = 1 + run.prng.random().uintLessThan(u64, run.model.head);
        try run.s.compact(revision, &run.diag);
        run.model.compacted = @max(run.model.compacted, revision);
    }

    /// The watch from the compaction point must replay exactly the history above it.
    fn check_replay(run: *ModelRun) !void {
        const model = &run.model;
        const start: store.WatchOptions = .{
            .prefix = "/m/",
            .from_revision = model.compacted + 1,
        };
        var watch = try run.s.watch(start, &run.diag);
        defer watch.close();
        const events = try drain(&watch, run.arena(), model.head, &run.diag);
        var index: usize = 0;
        for (model.events[0..model.count]) |*want| {
            if (want.revision <= model.compacted) continue;
            try testing.expect(index < events.len);
            const got = events[index];
            index += 1;
            try testing.expectEqual(want.kind, got.kind);
            try testing.expectEqualStrings(model_keys[want.key], got.kv.key);
            try testing.expectEqualStrings(want.value_slice(), got.kv.value);
            try testing.expectEqual(want.revision, got.kv.mod_revision);
            try testing.expectEqual(want.create_revision, got.kv.create_revision);
        }
        try testing.expectEqual(events.len, index);
    }
};

test "model: seeded random operations agree with a model of the store" {
    // Goal: the semantics of get, list, transactions, compaction and watch, checked against an
    // independent model over many random steps. Method: a seeded sequence of writes (puts and
    // deletes, up to three keys), compare-and-swap with right and wrong revisions, reads at
    // random revisions (including compacted and future ones), paginated lists, and compactions.
    // After every step the status must match the model, and at the end a watch from the
    // compaction point must replay exactly the model's history above it. The seed is printed;
    // `-Dseed=N` replays the run.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    const run = try testing.allocator.create(ModelRun);
    defer testing.allocator.destroy(run);
    run.* = .{
        .s = (try harness.connect()).interface(),
        .prng = harness.prng("model"),
        .arena_state = .init(testing.allocator),
    };
    defer run.arena_state.deinit();
    run.diag.reset();
    for (0..model_steps) |_| {
        _ = run.arena_state.reset(.retain_capacity);
        switch (run.prng.random().uintLessThan(u32, 100)) {
            0...34 => try run.step_write(),
            35...54 => try run.step_cas(),
            55...71 => try run.step_get(),
            72...95 => try run.step_list(),
            else => try run.step_compact(),
        }
        try run.check_status();
    }
    try run.check_replay();
}
