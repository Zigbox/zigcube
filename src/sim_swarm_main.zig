//! `sim-swarm`: runs the swarm simulation (`sim_swarm.zig`) natively and prints its report, for
//! one seed or for a range of them.
//!
//!     sim-swarm <seed> <operations>
//!     sim-swarm --seeds A..B <operations> [--shrink] [--expect-fail]
//!
//! A single seed prints its whole report. A range (`A..B` is inclusive of both) prints, per
//! failing seed, `seed N: FAILED: <what>` (the check, without the seed and time the full report
//! appends, so that every seed that fails alike prints the same words), `  step: <fetch|
//! locality>` (the operation it failed in), and the command that replays it; then a last line with
//! the counts. `--shrink` bisects the operations of each failing seed down to the smallest count
//! that still fails the same way (a run of fewer operations is a prefix of a longer one, so the
//! replay of what it prints is exact) and prints `  shrunk to N operations` and its replay. The
//! simulation fleet reads these lines (`sim_fleet_issue.zig`). `--expect-fail` is the teeth test
//! (`sim_swarm_teeth_main.zig`): it stops at the first seed that fails and exits 0 only if there
//! was one.
//!
//! Exit code 0 if every check held (or, with `--expect-fail`, one failed), 1 if one did not (or,
//! with `--expect-fail`, none did), and 2 for a usage error. A simulation, not a demo.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const sim_swarm = @import("sim_swarm.zig");

const usage_text = "usage: sim-swarm <seed> <operations>\n" ++
    "       sim-swarm --seeds A..B <operations> [--shrink] [--expect-fail]\n";

const Args = struct {
    first_seed: u64 = 0,
    last_seed: u64 = 0,
    range: bool = false,
    operations: u32 = 0,
    expect_fail: bool = false,
    shrink: bool = false,
};

/// Null if the arguments are not a valid command line.
fn parse(args: []const []const u8) ?Args {
    var parsed: Args = .{};
    var positional: [2][]const u8 = undefined;
    var positional_count: usize = 0;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--seeds")) {
            index += 1;
            if (index == args.len or !parse_range(&parsed, args[index])) return null;
        } else if (std.mem.eql(u8, arg, "--expect-fail")) {
            parsed.expect_fail = true;
        } else if (std.mem.eql(u8, arg, "--shrink")) {
            parsed.shrink = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return null;
        } else {
            if (positional_count == positional.len) return null;
            positional[positional_count] = arg;
            positional_count += 1;
        }
    }
    const skip: usize = if (parsed.range) 0 else 1;
    if (positional_count != skip + 1) return null;
    if (!parsed.range) {
        if (parsed.expect_fail or parsed.shrink) return null; // Those need a range.
        parsed.first_seed = std.fmt.parseInt(u64, positional[0], 0) catch return null;
        parsed.last_seed = parsed.first_seed;
    }
    // The shrinking reuses the report that `--expect-fail` reads afterwards.
    if (parsed.shrink and parsed.expect_fail) return null;
    parsed.operations = std.fmt.parseInt(u32, positional[skip], 10) catch return null;
    return parsed;
}

fn parse_range(parsed: *Args, text: []const u8) bool {
    const dots = std.mem.indexOf(u8, text, "..") orelse return false;
    parsed.first_seed = std.fmt.parseInt(u64, text[0..dots], 0) catch return false;
    parsed.last_seed = std.fmt.parseInt(u64, text[dots + 2 ..], 0) catch return false;
    parsed.range = true;
    return parsed.first_seed <= parsed.last_seed;
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return constants.exit_user;
    const parsed = parse(args) orelse return usage(init.io);
    if (parsed.operations == 0) return usage(init.io);
    const report = init.gpa.create(sim_swarm.Report) catch return constants.exit_environment;
    defer init.gpa.destroy(report);
    if (parsed.range) return run_range(init.io, &parsed, report);
    sim_swarm.simulate(parsed.first_seed, parsed.operations, report);
    write(init.io, report.text()) catch return constants.exit_environment;
    return if (report.failed) constants.exit_user else constants.exit_ok;
}

fn write(io: std.Io, text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

/// What the plan's test-only fault makes the simulation report.
const teeth_failure = "a chunk with wrong bytes was accepted";

/// The check that failed, without the " (seed N, at T ms)" the report appends: the same for
/// every seed that fails the same way. Empty if the report has no FAILED line.
fn symptom(report: *const sim_swarm.Report) []const u8 {
    const line = failure_line(report);
    if (line.len == 0) return "";
    const what = line["FAILED: ".len..];
    const tail = std.mem.lastIndexOf(u8, what, " (seed ") orelse return what;
    return what[0..tail];
}

/// The smallest number of operations at most `failing` that fails with `what`. A bisection, as
/// in `sim_cluster_main.zig`: it assumes that if `n` operations fail so do `n + 1`.
fn shrink(seed: u64, failing: u32, what: []const u8, report: *sim_swarm.Report) u32 {
    assert(failing > 0);
    var fails_low: u32 = 0; // Known not to fail (or to fail differently).
    var fails_high: u32 = failing; // Known to fail with `what`.
    while (fails_high - fails_low > 1) {
        const middle = fails_low + @divFloor(fails_high - fails_low, 2);
        sim_swarm.simulate(seed, middle, report);
        if (report.failed and std.mem.eql(u8, symptom(report), what)) {
            fails_high = middle;
        } else {
            fails_low = middle;
        }
    }
    return fails_high;
}

/// The FAILED line of a report, without its newline.
fn failure_line(report: *const sim_swarm.Report) []const u8 {
    const text = report.text();
    const start = std.mem.indexOf(u8, text, "FAILED: ") orelse return "";
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return text[start..end];
}

/// Prints a failing seed's lines; `report` holds its run, and is reused by the shrinking.
fn report_failure(
    out: *std.Io.Writer,
    parsed: *const Args,
    seed: u64,
    report: *sim_swarm.Report,
) !void {
    var what_buffer: [256]u8 = undefined;
    const what_text = symptom(report);
    const what = what_buffer[0..@min(what_text.len, what_buffer.len)];
    @memcpy(what, what_text[0..what.len]);
    var step_buffer: [32]u8 = undefined;
    const step_text = report.step;
    const step = step_buffer[0..@min(step_text.len, step_buffer.len)];
    @memcpy(step, step_text[0..step.len]);
    try out.print("seed {d}: FAILED: {s}\n  step: {s}\n", .{ seed, what, step });
    try out.print("  replay: zig-out/bin/sim_swarm {d} {d}\n", .{ seed, parsed.operations });
    if (!parsed.shrink) return;
    const smallest = shrink(seed, parsed.operations, what, report);
    try out.print("  shrunk to {d} operations\n", .{smallest});
    try out.print("  replay: zig-out/bin/sim_swarm {d} {d}\n", .{ seed, smallest });
}

fn run_range(io: std.Io, parsed: *const Args, report: *sim_swarm.Report) u8 {
    var buffer: [1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;
    defer out.flush() catch {}; // Nowhere else to report it.
    var failures: u64 = 0;
    var seed = parsed.first_seed;
    while (true) : (seed += 1) {
        sim_swarm.simulate(seed, parsed.operations, report);
        if (report.failed) {
            failures += 1;
            report_failure(out, parsed, seed, report) catch return constants.exit_environment;
            out.flush() catch return constants.exit_environment;
            if (parsed.expect_fail) {
                // Only the failure the teeth fault provokes counts: any other is a real bug.
                if (std.mem.indexOf(u8, failure_line(report), teeth_failure) == null) {
                    out.print("sim-swarm: seed {d} failed otherwise than the teeth fault\n", .{
                        seed,
                    }) catch return constants.exit_environment;
                    return constants.exit_user;
                }
                break; // Caught: that is all the teeth test asks.
            }
        }
        if (seed == parsed.last_seed) break;
    }
    if (parsed.expect_fail and failures > 0) {
        out.print("sim-swarm: caught at seed {d} of {d}..{d}\n", .{
            seed, parsed.first_seed, parsed.last_seed,
        }) catch return constants.exit_environment;
        return constants.exit_ok;
    }
    out.print("sim-swarm: seeds {d}..{d}, {d} operations: {d} of {d} failed\n", .{
        parsed.first_seed,                        parsed.last_seed, parsed.operations, failures,
        parsed.last_seed - parsed.first_seed + 1,
    }) catch return constants.exit_environment;
    const held = failures == 0;
    return if (held != parsed.expect_fail) constants.exit_ok else constants.exit_user;
}

fn usage(io: std.Io) u8 {
    std.Io.File.stderr().writeStreamingAll(io, usage_text) catch {}; // Nowhere else to report it.
    return 2;
}

test "the command lines: one seed, a range, and what is refused" {
    const single = parse(&.{ "sim", "7", "100" }).?;
    try std.testing.expect(!single.range);
    try std.testing.expectEqual(@as(u64, 7), single.first_seed);
    try std.testing.expectEqual(@as(u32, 100), single.operations);
    const range = parse(&.{ "sim", "--seeds", "5..9", "60", "--expect-fail" }).?;
    try std.testing.expect(range.range and range.expect_fail);
    try std.testing.expectEqual(@as(u64, 9), range.last_seed);
    try std.testing.expect(parse(&.{ "sim", "--seeds", "9..5", "60" }) == null);
    try std.testing.expect(parse(&.{ "sim", "7", "60", "--expect-fail" }) == null);
    try std.testing.expect(parse(&.{ "sim", "7" }) == null);
    try std.testing.expect(parse(&.{ "sim", "7", "60", "--nope" }) == null);
    try std.testing.expect(parse(&.{ "sim", "--seeds", "5..9", "60", "--shrink" }).?.shrink);
    try std.testing.expect(parse(&.{ "sim", "7", "60", "--shrink" }) == null);
    const both = parse(&.{ "sim", "--seeds", "5..9", "60", "--shrink", "--expect-fail" });
    try std.testing.expect(both == null);
}

test "a failing report gives its check without the seed, and its step" {
    var report: sim_swarm.Report = .{ .failed = true, .step = "fetch" };
    const text = "FAILED: a peer was asked twice for the same chunk (seed 9, at 1234 ms)\n";
    @memcpy(report.bytes[0..text.len], text);
    report.len = text.len;
    const what = "a peer was asked twice for the same chunk";
    try std.testing.expectEqualStrings(what, symptom(&report));
    var clean: sim_swarm.Report = .{};
    try std.testing.expectEqualStrings("", symptom(&clean));
}
