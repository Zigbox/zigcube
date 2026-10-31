//! Drives the controller: the shell half of the step model (docs/core.md). The core's
//! `reconcile(ctx)` does what is due and says when it next needs to run; this file waits for that
//! (a timer, or a change under the prefixes it named) and calls it again. It also does what the
//! core must not: expires leases and compacts the store on timers, reports a failing store as a
//! diagnostic once and not once a step, and backs off.
//!
//! One thread runs `run`. It owns one store watch, opened before the first step so that a change
//! made during a step is waiting for the next wait rather than lost.

const std = @import("std");
const assert = std.debug.assert;
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const Clock = @import("clock.zig").Clock;
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const BoundedArena = @import("server_arena.zig").BoundedArena;
const replica_controller = @import("replica_controller.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const Driver = struct {
    gpa: Allocator,
    io: std.Io,
    store: store.Store,
    clock: Clock,
    replicas: replica_controller.ReplicaController,
    stopping: *const std.atomic.Value(bool),
    /// Print a coded diagnostic for a failing step; false in tests that make the store fail.
    report_failures: bool,
    // What was last reported, so that a store that stays down is shown once.
    last_code: ?codes.Code = null,
    last_report_ms: u64 = 0,
    /// Steps that ran, for tests and the status line.
    steps: std.atomic.Value(u64) = .init(0),

    const Wait = enum { due, store_trouble };

    /// Runs until `stopping` is set. Never returns an error: a failing store is retried for as
    /// long as the server lives, and every failure is a diagnostic.
    pub fn run(driver: *Driver) void {
        var arena = BoundedArena.init(driver.gpa, constants.request_arena_bytes_max);
        defer arena.deinit();
        var diag: Diag = undefined;
        diag.reset();
        var watch: ?store.Watch = driver.open_watch(&diag);
        defer if (watch) |*open| open.close();
        var retry_ms: u32 = constants.server_retry_ms_min;
        var due = driver.start_timers();
        while (!driver.stopping.load(.acquire)) {
            arena.reset();
            diag.reset();
            const ctx: controller.Context = .{
                .store = driver.store,
                .clock = driver.clock,
                .arena = arena.allocator(),
                .diag = &diag,
            };
            const wake = driver.step(&ctx) catch {
                driver.report(&diag);
                if (watch) |*open| open.close();
                watch = null;
                driver.pause(retry_ms);
                retry_ms = @min(retry_ms * 2, constants.server_retry_ms_max);
                if (watch == null) watch = driver.open_watch(&diag);
                continue;
            };
            _ = driver.steps.fetchAdd(1, .monotonic);
            driver.recovered();
            retry_ms = constants.server_retry_ms_min;
            if (watch == null) watch = driver.open_watch(&diag);
            _ = driver.wait(&watch, wake, &due, &arena, &diag);
        }
    }

    /// One step: first the store is checked against what the server remembers (a `status` through
    /// the `VerifiedStore`, which halts everything on a store that went backwards), then the
    /// controller runs.
    fn step(driver: *Driver, ctx: *const controller.Context) controller.Error!controller.Wakeup {
        _ = try driver.store.status(ctx.diag);
        return driver.replicas.reconcile(ctx);
    }

    const Timers = struct { maintenance_due_ms: u64, compact_due_ms: u64 };

    fn start_timers(driver: *Driver) Timers {
        const now = driver.clock.now_ms();
        return .{
            .maintenance_due_ms = now,
            .compact_due_ms = now + constants.server_compact_ms,
        };
    }

    /// A watch on every key from the store's next revision, or null if the store is unreachable
    /// (the next step reports it and tries again).
    fn open_watch(driver: *Driver, diag: *Diag) ?store.Watch {
        diag.reset();
        const status = driver.store.status(diag) catch {
            diag.reset();
            return null;
        };
        const options: store.WatchOptions = .{ .prefix = "", .from_revision = status.revision + 1 };
        return driver.store.watch(options, diag) catch {
            diag.reset();
            return null;
        };
    }

    /// Waits until the controller is due, or a key under its prefixes changes, running the
    /// maintenance that is due meanwhile.
    fn wait(
        driver: *Driver,
        watch: *?store.Watch,
        wake: controller.Wakeup,
        due: *Timers,
        arena: *BoundedArena,
        diag: *Diag,
    ) Wait {
        while (!driver.stopping.load(.acquire)) {
            const now = driver.clock.now_ms();
            if (now >= wake.at_ms) return .due;
            if (now >= due.maintenance_due_ms) driver.maintain(due, diag);
            const open = &(watch.* orelse {
                driver.pause(@intCast(@min(wake.at_ms - now, constants.server_retry_ms_min)));
                return .store_trouble;
            });
            const until = @min(wake.at_ms, due.maintenance_due_ms);
            const slice: u32 = @intCast(@min(until -| now, constants.http_hold_slice_ms));
            arena.reset();
            diag.reset();
            const batch = open.next(arena.allocator(), slice, diag) catch {
                // Behind the compaction point, or the store went away: drop the watch; the next
                // step re-reads everything and reopens it.
                diag.reset();
                open.close();
                watch.* = null;
                return .store_trouble;
            };
            for (batch.events) |event| {
                for (wake.prefixes) |prefix| {
                    if (std.mem.startsWith(u8, event.kv.key, prefix)) return .due;
                }
            }
            // A store that does not wait (the memory store) answers at once: do not spin on it.
            const waited = driver.clock.now_ms() -| now;
            if (batch.events.len == 0) {
                if (waited < slice) {
                    const left: u32 = slice - @as(u32, @intCast(waited));
                    driver.pause(@min(left, constants.server_poll_ms));
                }
            }
        }
        return .due;
    }

    /// Expires leases every `server_maintenance_ms`, and compacts every `server_compact_ms`,
    /// keeping `server_compact_keep_revisions` of history. A store that fails is the next step's
    /// to report; here the work is only skipped.
    fn maintain(driver: *Driver, due: *Timers, diag: *Diag) void {
        const now = driver.clock.now_ms();
        due.maintenance_due_ms = now + constants.server_maintenance_ms;
        diag.reset();
        _ = driver.store.expire_leases(diag) catch diag.reset();
        if (now < due.compact_due_ms) return;
        due.compact_due_ms = now + constants.server_compact_ms;
        const status = driver.store.status(diag) catch {
            diag.reset();
            return;
        };
        const keep: store.Revision = constants.server_compact_keep_revisions;
        if (status.revision <= keep) return;
        const target = status.revision - keep;
        if (target <= status.compacted_revision) return;
        driver.store.compact(target, diag) catch diag.reset();
    }

    fn pause(driver: *Driver, ms: u32) void {
        // Cancelled: the loop's own check then ends it.
        driver.io.sleep(.fromMilliseconds(ms), .awake) catch {};
    }

    // ---- Failures, shown once ----

    fn report(driver: *Driver, diag: *Diag) void {
        const code = diag.code orelse return;
        const now = driver.clock.now_ms();
        if (driver.last_code == code) {
            if (now -| driver.last_report_ms < constants.server_report_ms) return;
        }
        driver.last_code = code;
        driver.last_report_ms = now;
        if (!driver.report_failures) return;
        var diagnostic: diag_mod.Diagnostic = undefined;
        diag_mod.to_diagnostic(&diagnostic, diag);
        var buffer: [constants.diag_output_bytes_max]u8 = undefined;
        const text = diag_mod.render(&diagnostic, .text, false, &buffer);
        const file = std.Io.File.stderr();
        const before = "\nzcube-server: the controller could not finish a step\n";
        const after = "zcube-server: retrying; workloads keep running meanwhile\n";
        file.writeStreamingAll(driver.io, before) catch {};
        file.writeStreamingAll(driver.io, text) catch {};
        file.writeStreamingAll(driver.io, after) catch {};
    }

    fn recovered(driver: *Driver) void {
        if (driver.last_code == null) return;
        driver.last_code = null;
        if (!driver.report_failures) return;
        const line = "zcube-server: the controller is running again\n";
        std.Io.File.stderr().writeStreamingAll(driver.io, line) catch {};
    }
};
