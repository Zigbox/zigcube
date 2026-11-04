//! `sim-cluster`: runs the deterministic cluster simulation natively and prints its report, for
//! one seed or for a range of them.
//!
//!     sim-cluster <seed> <operations> [<nodes>] [--liveness=true|false] [--heal-at=N]
//!                 [--trace-steps]
//!     sim-cluster --seeds A..B <operations> [<nodes>] [--liveness=true|false] [--shrink]
//!                 [--expect-fail] [--trace-steps]
//!
//! `<nodes>` 0 lets the seed pick. Liveness is on by default (src/sim_cluster.zig says what it
//! is). `--heal-at=N` makes the faults end before operation N instead of where the seed chose.
//!
//! A single seed prints its whole report. A range (`A..B` is inclusive of both) prints one line
//! per failing seed, `seed N: FAILED: <what>`, `  step: <faults|healed|convergence|end>` (where the
//! run was), then the command that replays it, and a last line
//! with the counts. `--shrink` bisects the operations of each failing seed down to the smallest
//! count that still fails the same way, with the heal point held where the full run had it, so
//! the printed replay command (with `--heal-at`) reproduces exactly that shorter run.
//! `--expect-fail` turns the range into the teeth test (`sim_teeth_main.zig`): it stops at the
//! first seed that fails and exits 0 only if there was one.
//!
//! `--c1` runs sim-c1 (docs/core.md, "sim-c1"): the per-revision checks of docs/authority.md §4.
//! `--expect-symptom=TEXT` with `--expect-fail` makes the failure count only if it starts with
//! TEXT; the negative tests of sim-c1 use it (`sim_c1_teeth_main.zig`).
//!
//! `--trace-steps` writes `step: <name>` to stderr, unbuffered, as each run enters a step
//! ("faults", "healed", "convergence", "end"), so a run that panics leaves where it was: the
//! simulation fleet's runner files a crash under that step (ops/sim-fleet/run.sh). A range writes
//! each failing seed's lines as soon as it has them, so a later crash does not lose them.
//!
//! Exit code 0 if every check held (or, with `--expect-fail`, one failed), 1 if one did not (or,
//! with `--expect-fail`, none did), and 2 for a usage error. A simulation, not a demo.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const sim_cluster = @import("sim_cluster.zig");

const usage_text = "usage: sim-cluster <seed> <operations> [<nodes>] [--liveness=true|false] " ++
    "[--heal-at=N] [--trace-steps]\n       sim-cluster --seeds A..B <operations> [<nodes>] " ++
    "[--liveness=true|false] [--shrink] [--expect-fail] [--trace-steps]\n";

/// What the command line asked for.
const Args = struct {
    first_seed: u64 = 0,
    last_seed: u64 = 0,
    range: bool = false,
    operations: u32 = 0,
    options: sim_cluster.Options = .{},
    shrink: bool = false,
    expect_fail: bool = false,
    trace_steps: bool = false,
    /// `--expect-symptom=TEXT` (with `--expect-fail`): the failure must start with TEXT ("I6"),
    /// so a negative test passes only if the check it is about is the one that fired.
    expect_symptom: ?[]const u8 = null,
};

/// Null if the arguments are not a valid command line.
fn parse(args: []const []const u8) ?Args {
    var parsed: Args = .{};
    var positional: [3][]const u8 = undefined;
    var positional_count: u32 = 0;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--seeds")) {
            index += 1;
            if (index == args.len) return null;
            if (!parse_range(&parsed, args[index])) return null;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            if (!parse_flag(&parsed, arg)) return null;
        } else {
            if (positional_count == positional.len) return null;
            positional[positional_count] = arg;
            positional_count += 1;
        }
    }
    // The single form leads with its seed; the range form has none.
    const skip: u32 = if (parsed.range) 0 else 1;
    if (positional_count < skip + 1 or positional_count > skip + 2) return null;
    if (!parsed.range) {
        if (parsed.shrink or parsed.expect_fail) return null; // These need a range.
        if (parsed.expect_symptom != null) return null;
        parsed.first_seed = std.fmt.parseInt(u64, positional[0], 0) catch return null;
        parsed.last_seed = parsed.first_seed;
    } else if (parsed.options.heal_at != null) {
        return null; // Each seed in a range draws its own.
    }
    parsed.operations = std.fmt.parseInt(u32, positional[skip], 10) catch return null;
    if (positional_count == skip + 2) {
        const count = std.fmt.parseInt(u32, positional[skip + 1], 10) catch return null;
        if (count > sim_cluster.nodes_max) return null;
        parsed.options.nodes = if (count == 0) null else count;
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

fn parse_flag(parsed: *Args, arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "--liveness=true")) {
        parsed.options.liveness = true;
    } else if (std.mem.eql(u8, arg, "--liveness=false")) {
        parsed.options.liveness = false;
    } else if (std.mem.eql(u8, arg, "--shrink")) {
        parsed.shrink = true;
    } else if (std.mem.eql(u8, arg, "--expect-fail")) {
        parsed.expect_fail = true;
    } else if (std.mem.eql(u8, arg, "--c1")) {
        parsed.options.c1 = true;
    } else if (std.mem.startsWith(u8, arg, "--expect-symptom=")) {
        parsed.expect_symptom = arg["--expect-symptom=".len..];
    } else if (std.mem.eql(u8, arg, "--trace-steps")) {
        parsed.trace_steps = true;
    } else if (std.mem.startsWith(u8, arg, "--heal-at=")) {
        parsed.options.heal_at = std.fmt.parseInt(u32, arg["--heal-at=".len..], 10) catch
            return false;
    } else {
        return false;
    }
    return true;
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return constants.exit_user;
    var parsed = parse(args) orelse return usage(init.io);
    if (parsed.operations == 0) return usage(init.io);
    if (parsed.trace_steps) {
        trace_io = init.io;
        parsed.options.on_step = trace_step;
    }
    const report = init.gpa.create(sim_cluster.Report) catch return constants.exit_environment;
    defer init.gpa.destroy(report);
    if (parsed.range) return run_range(init, &parsed, report);
    sim_cluster.simulate(init.gpa, parsed.first_seed, parsed.operations, parsed.options, report);
    write(init.io, report.text()) catch return constants.exit_environment;
    if (report.failed) return constants.exit_user;
    return constants.exit_ok;
}

/// The process's I/O, for `trace_step`, which the simulation calls without one.
var trace_io: ?std.Io = null;

/// `--trace-steps`: one unbuffered stderr line per step, so it survives a panic.
fn trace_step(step: []const u8) void {
    assert(step.len > 0);
    const io = trace_io.?;
    var line_buffer: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, "step: {s}\n", .{step}) catch
        "step: (name too long)\n";
    std.Io.File.stderr().writeStreamingAll(io, line) catch {}; // Nowhere else to report it.
}

fn write(io: std.Io, text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

/// The text of the report's FAILED line without its trailing "(seed N, at T ms)": the symptom,
/// which is the same for every seed that fails the same way.
fn symptom(report: *const sim_cluster.Report) []const u8 {
    const text = report.text();
    const start = std.mem.indexOf(u8, text, "FAILED: ") orelse return "";
    const line_end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    const line = text[start + "FAILED: ".len .. line_end];
    const tail = std.mem.lastIndexOf(u8, line, " (seed ") orelse return line;
    return line[0..tail];
}

/// The step line of the report ("faults", "healed", "convergence" or "end"): where the run was
/// when the check failed. Empty if the report has none.
fn step_of(report: *const sim_cluster.Report) []const u8 {
    const text = report.text();
    const start = std.mem.indexOf(u8, text, "\nstep: ") orelse return "";
    const from = start + "\nstep: ".len;
    const line_end = std.mem.indexOfScalarPos(u8, text, from, '\n') orelse text.len;
    return text[from..line_end];
}

/// The smallest number of operations at most `failing` that fails with `what`, with the faults
/// ending before operation `heal_at` as in the full run. A bisection: it assumes that if `n`
/// operations fail, so do `n + 1`, and checks only that the answer fails and one fewer does not
/// (a run's failure can come and go as the count grows; the replay of what it prints is exact).
fn shrink(
    init: std.process.Init,
    seed: u64,
    failing: u32,
    options: sim_cluster.Options,
    what: []const u8,
    report: *sim_cluster.Report,
) u32 {
    const pinned = options;
    var fails_low: u32 = 0; // Known not to fail (or to fail differently).
    var fails_high: u32 = failing; // Known to fail with `what`.
    assert(pinned.heal_at != null);
    while (fails_high - fails_low > 1) {
        const middle = fails_low + @divFloor(fails_high - fails_low, 2);
        sim_cluster.simulate(init.gpa, seed, middle, pinned, report);
        if (report.failed and std.mem.eql(u8, symptom(report), what)) {
            fails_high = middle;
        } else {
            fails_low = middle;
        }
    }
    return fails_high;
}

/// Prints the command that reproduces a run, to `out`.
fn print_replay(
    out: *std.Io.Writer,
    seed: u64,
    operations: u32,
    options: sim_cluster.Options,
    heal_at: ?u32,
) !void {
    try out.print("  replay: zig-out/bin/sim_cluster {d} {d} {d}", .{
        seed, operations, options.nodes orelse 0,
    });
    if (!options.liveness) try out.writeAll(" --liveness=false");
    if (options.c1) try out.writeAll(" --c1");
    if (heal_at) |point| try out.print(" --heal-at={d}", .{point});
    try out.writeAll("\n");
}

fn run_range(init: std.process.Init, parsed: *const Args, report: *sim_cluster.Report) u8 {
    var buffer: [1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &file_writer.interface;
    defer out.flush() catch {}; // Nowhere else to report it.
    var failures: u64 = 0;
    var seed = parsed.first_seed;
    while (true) : (seed += 1) {
        sim_cluster.simulate(init.gpa, seed, parsed.operations, parsed.options, report);
        if (report.failed) {
            failures += 1;
            report_failure(init, parsed, seed, report, out) catch return constants.exit_environment;
            // Out now: a crash on a later seed must not lose it.
            out.flush() catch return constants.exit_environment;
            if (parsed.expect_fail) {
                // Caught, and that is all the teeth test asks, if it is the right check.
                if (parsed.expect_symptom) |want| {
                    if (!std.mem.startsWith(u8, symptom(report), want)) {
                        out.print("sim-cluster: seed {d} failed, but not with \"{s}\"\n", .{
                            seed, want,
                        }) catch return constants.exit_environment;
                        return constants.exit_user;
                    }
                }
                break;
            }
        }
        if (seed == parsed.last_seed) break;
    }
    if (parsed.expect_fail and failures > 0) {
        out.print("sim-cluster: caught at seed {d} of {d}..{d}\n", .{
            seed, parsed.first_seed, parsed.last_seed,
        }) catch return constants.exit_environment;
        return constants.exit_ok;
    }
    const total = parsed.last_seed - parsed.first_seed + 1;
    out.print("sim-cluster: seeds {d}..{d}, {d} operations: {d} of {d} failed\n", .{
        parsed.first_seed, parsed.last_seed, parsed.operations, failures, total,
    }) catch return constants.exit_environment;
    if (parsed.expect_fail) return if (failures > 0) constants.exit_ok else constants.exit_user;
    return if (failures == 0) constants.exit_ok else constants.exit_user;
}

fn report_failure(
    init: std.process.Init,
    parsed: *const Args,
    seed: u64,
    report: *sim_cluster.Report,
    out: *std.Io.Writer,
) !void {
    var what_buffer: [256]u8 = undefined;
    const what_text = symptom(report);
    const what = what_buffer[0..@min(what_text.len, what_buffer.len)];
    @memcpy(what, what_text[0..what.len]);
    try out.print("seed {d}: FAILED: {s}\n", .{ seed, what });
    try out.print("  step: {s}\n", .{step_of(report)});
    const heal_at: ?u32 = if (parsed.options.liveness)
        sim_cluster.heal_point(seed, parsed.operations)
    else
        null;
    try print_replay(out, seed, parsed.operations, parsed.options, heal_at);
    if (!parsed.shrink) return;
    var pinned = parsed.options;
    pinned.heal_at = heal_at orelse parsed.operations;
    const smallest = shrink(init, seed, parsed.operations, pinned, what, report);
    try out.print("  shrunk to {d} operations\n", .{smallest});
    try print_replay(out, seed, smallest, parsed.options, heal_at);
}

fn usage(io: std.Io) u8 {
    std.Io.File.stderr().writeStreamingAll(io, usage_text) catch {}; // Nowhere else to report it.
    return 2;
}

test "the command lines: one seed, a range, and what is refused" {
    const single = parse(&.{ "sim", "7", "100", "3", "--liveness=false", "--heal-at=40" }).?;
    try std.testing.expect(!single.range);
    try std.testing.expectEqual(@as(u64, 7), single.first_seed);
    try std.testing.expectEqual(@as(u32, 100), single.operations);
    try std.testing.expectEqual(@as(?u32, 3), single.options.nodes);
    try std.testing.expectEqual(@as(?u32, 40), single.options.heal_at);
    try std.testing.expect(!single.options.liveness);

    const range = parse(&.{ "sim", "--seeds", "5..9", "60", "--shrink" }).?;
    try std.testing.expect(range.range and range.shrink);
    try std.testing.expectEqual(@as(u64, 5), range.first_seed);
    try std.testing.expectEqual(@as(u64, 9), range.last_seed);
    try std.testing.expectEqual(@as(u32, 60), range.operations);
    try std.testing.expectEqual(@as(?u32, null), range.options.nodes);

    try std.testing.expect(parse(&.{ "sim", "--seeds", "9..5", "60" }) == null);
    try std.testing.expect(parse(&.{ "sim", "--seeds", "5..9", "60", "--heal-at=3" }) == null);
    try std.testing.expect(parse(&.{ "sim", "7", "60", "--shrink" }) == null);
    try std.testing.expect(parse(&.{ "sim", "7" }) == null);
    try std.testing.expect(parse(&.{ "sim", "7", "60", "--nope" }) == null);
    const traced = parse(&.{ "sim", "--seeds", "1..1", "60", "--trace-steps" }).?;
    try std.testing.expect(traced.trace_steps);
}

test "a shrunk run is the run: the heal point held, the same symptom" {
    const gpa = std.testing.allocator;
    const report = try gpa.create(sim_cluster.Report);
    defer gpa.destroy(report);
    const seed = 3;
    const heal_at = sim_cluster.heal_point(seed, 60);
    sim_cluster.simulate(gpa, seed, 60, .{ .heal_at = heal_at }, report);
    var full: sim_cluster.Report = undefined;
    sim_cluster.simulate(gpa, seed, 60, .{}, &full);
    // Pinning the heal point to the seed's own choice changes nothing.
    try std.testing.expectEqualStrings(full.text(), report.text());
}

var traced_steps: [8][]const u8 = undefined;
var traced_count: usize = 0;

fn record_step(step: []const u8) void {
    assert(traced_count < traced_steps.len);
    traced_steps[traced_count] = step;
    traced_count += 1;
}

test "the step hook hears every step the run enters, in order" {
    // Goal: H3, `--trace-steps` can say where a crashing run was. Method: run a passing seed
    // with a recording hook and check the steps it heard.
    const gpa = std.testing.allocator;
    const report = try gpa.create(sim_cluster.Report);
    defer gpa.destroy(report);
    traced_count = 0;
    sim_cluster.simulate(gpa, 3, 60, .{ .on_step = record_step }, report);
    try std.testing.expect(!report.failed);
    try std.testing.expectEqual(@as(usize, 4), traced_count);
    try std.testing.expectEqualStrings("faults", traced_steps[0]);
    try std.testing.expectEqualStrings("healed", traced_steps[1]);
    try std.testing.expectEqualStrings("convergence", traced_steps[2]);
    try std.testing.expectEqualStrings("end", traced_steps[3]);
}

test "a short fault phase is not judged by one request per operation (fleet issue 56)" {
    // Goal: regression for the simulation fleet's issue 56. Method: replay the two shrunk
    // failures (73 operations healing at 79, 38 operations healing at 50); each had 47 and 31
    // virtual seconds of faults and delivered one request fewer than it had operations, which is
    // luck (a lost call costs 10 s), not a cluster that stopped working. Both must now pass. The
    // seeds stop reproducing those short runs when the simulator's draw changes; the lasting
    // check is the unit test of `request_floor_met` in sim_cluster.zig.
    const Replay = struct { seed: u64, operations: u32, heal_at: u32 };
    const report = try std.testing.allocator.create(sim_cluster.Report);
    defer std.testing.allocator.destroy(report);
    for ([_]Replay{
        .{ .seed = 3491114665, .operations = 73, .heal_at = 79 },
        .{ .seed = 1995814075, .operations = 38, .heal_at = 50 },
    }) |replay| {
        sim_cluster.simulate(std.testing.allocator, replay.seed, replay.operations, .{
            .heal_at = replay.heal_at,
        }, report);
        if (report.failed) std.debug.print("{s}\n", .{report.text()});
        try std.testing.expect(!report.failed);
    }
}

test "a service deleted and applied again leaves no old replica running (fleet issue 55)" {
    // Goal: regression for the simulation fleet's issue 55. Method: replay the shrunk failure
    // (78 operations healing at 98): alpha was deleted and applied again between two controller
    // steps, its old replica alpha-6 (generation 2) survived the new service (generation 1), and
    // an apply of a broken image brought the service to generation 2, so alpha-6 ran for ever.
    // A pinned seed stops reproducing the race when the simulator's draw changes (a new
    // operation or a changed weight moves every later draw), so this test can start passing for
    // the wrong reason; the lasting regression is the controller unit test of the cause,
    // replica_controller_test.zig.
    const report = try std.testing.allocator.create(sim_cluster.Report);
    defer std.testing.allocator.destroy(report);
    sim_cluster.simulate(std.testing.allocator, 2352517332, 78, .{ .heal_at = 98 }, report);
    if (report.failed) std.debug.print("{s}\n", .{report.text()});
    try std.testing.expect(!report.failed);
}
