//! `sim-swarm`: runs the swarm simulation (`sim_swarm.zig`) natively and prints its report, for
//! one seed or for a range of them.
//!
//!     sim-swarm <seed> <operations|auto> [--profile=NAME|auto]
//!     sim-swarm --seeds A..B <operations|auto> [--profile=NAME|auto] [--expect-fail]
//!
//! A single seed prints its whole report. A range (`A..B` is inclusive of both) prints one line
//! per failing seed, `seed N: FAILED: <what>`, then the command that replays it, and a last line
//! with the counts. `--expect-fail` is the teeth test (`sim_swarm_teeth_main.zig`): it stops at
//! the first seed that fails and exits 0 only if there was one.
//!
//! Exit code 0 if every check held (or, with `--expect-fail`, one failed), 1 if one did not (or,
//! with `--expect-fail`, none did), and 2 for a usage error. A simulation, not a demo.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const sim_shape = @import("sim_shape.zig");
const sim_swarm = @import("sim_swarm.zig");

const usage_text = "usage: sim-swarm <seed> <operations|auto> [--profile=NAME|auto]\n" ++
    "       sim-swarm --seeds A..B <operations|auto> [--profile=NAME|auto] [--expect-fail]\n" ++
    "  profiles: mixed (default), liars, silent, refusers, honest; auto draws one per seed\n";

const Args = struct {
    first_seed: u64 = 0,
    last_seed: u64 = 0,
    range: bool = false,
    /// Null draws the operations from the seed.
    operations: ?u32 = null,
    /// Null (`--profile=auto`) draws the profile from the seed.
    profile: ?sim_shape.SwarmProfile = .mixed,
    expect_fail: bool = false,
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
        } else if (std.mem.startsWith(u8, arg, "--profile=")) {
            const name = arg["--profile=".len..];
            parsed.profile = if (std.mem.eql(u8, name, "auto"))
                null
            else
                sim_shape.SwarmProfile.parse(name) orelse return null;
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
        if (parsed.expect_fail) return null; // That needs a range.
        parsed.first_seed = std.fmt.parseInt(u64, positional[0], 0) catch return null;
        parsed.last_seed = parsed.first_seed;
    }
    if (!std.mem.eql(u8, positional[skip], "auto")) {
        const operations = std.fmt.parseInt(u32, positional[skip], 10) catch return null;
        if (operations == 0) return null;
        parsed.operations = operations;
    }
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
    const report = init.gpa.create(sim_swarm.Report) catch return constants.exit_environment;
    defer init.gpa.destroy(report);
    if (parsed.range) return run_range(init.io, &parsed, report);
    const resolved = sim_swarm.resolve(parsed.first_seed, parsed.operations, parsed.profile);
    sim_swarm.simulate_profile(parsed.first_seed, resolved.operations, resolved.profile, report);
    write(init.io, report.text()) catch return constants.exit_environment;
    return if (report.failed) constants.exit_user else constants.exit_ok;
}

fn write(io: std.Io, text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

/// The FAILED line of a report, without its newline.
/// What the plan's test-only fault makes the simulation report.
const teeth_failure = "a chunk with wrong bytes was accepted";

fn failure_line(report: *const sim_swarm.Report) []const u8 {
    const text = report.text();
    const start = std.mem.indexOf(u8, text, "FAILED: ") orelse return "";
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return text[start..end];
}

fn run_range(io: std.Io, parsed: *const Args, report: *sim_swarm.Report) u8 {
    var buffer: [1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;
    defer out.flush() catch {}; // Nowhere else to report it.
    var failures: u64 = 0;
    var seed = parsed.first_seed;
    while (true) : (seed += 1) {
        const resolved = sim_swarm.resolve(seed, parsed.operations, parsed.profile);
        sim_swarm.simulate_profile(seed, resolved.operations, resolved.profile, report);
        if (report.failed) {
            failures += 1;
            // Concrete, so the replay needs no draw.
            out.print("seed {d}: {s}\n  profile: {s}\n  replay: zig-out/bin/sim_swarm {d} {d}", .{
                seed, failure_line(report), resolved.profile.name(), seed, resolved.operations,
            }) catch return constants.exit_environment;
            out.print(" --profile={s}\n", .{resolved.profile.name()}) catch
                return constants.exit_environment;
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
    const total = parsed.last_seed - parsed.first_seed + 1;
    if (parsed.operations) |operations| {
        out.print("sim-swarm: seeds {d}..{d}, {d} operations: {d} of {d} failed\n", .{
            parsed.first_seed, parsed.last_seed, operations, failures, total,
        }) catch return constants.exit_environment;
    } else {
        out.print("sim-swarm: seeds {d}..{d}, drawn operations: {d} of {d} failed\n", .{
            parsed.first_seed, parsed.last_seed, failures, total,
        }) catch return constants.exit_environment;
    }
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
    try std.testing.expectEqual(@as(?u32, 100), single.operations);
    try std.testing.expectEqual(@as(?sim_shape.SwarmProfile, .mixed), single.profile);
    const drawn = parse(&.{ "sim", "--seeds", "1..3", "auto", "--profile=auto" }).?;
    try std.testing.expectEqual(@as(?u32, null), drawn.operations);
    try std.testing.expectEqual(@as(?sim_shape.SwarmProfile, null), drawn.profile);
    const liars = parse(&.{ "sim", "7", "60", "--profile=liars" }).?;
    try std.testing.expectEqual(@as(?sim_shape.SwarmProfile, .liars), liars.profile);
    try std.testing.expect(parse(&.{ "sim", "7", "60", "--profile=nope" }) == null);
    try std.testing.expect(parse(&.{ "sim", "7", "0" }) == null);
    const range = parse(&.{ "sim", "--seeds", "5..9", "60", "--expect-fail" }).?;
    try std.testing.expect(range.range and range.expect_fail);
    try std.testing.expectEqual(@as(u64, 9), range.last_seed);
    try std.testing.expect(parse(&.{ "sim", "--seeds", "9..5", "60" }) == null);
    try std.testing.expect(parse(&.{ "sim", "7", "60", "--expect-fail" }) == null);
    try std.testing.expect(parse(&.{ "sim", "7" }) == null);
    try std.testing.expect(parse(&.{ "sim", "7", "60", "--nope" }) == null);
}
