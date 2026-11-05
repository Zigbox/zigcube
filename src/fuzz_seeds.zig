//! Seeds and replay for the seeded fuzzers (`x509_fuzz.zig`, `peer_fuzz.zig`). A run has one
//! master seed; iteration `i` runs with the `i`-th output of SplitMix64 over it. A failure prints
//! both seeds, each with the environment that replays it:
//!
//!   ZCUBE_FUZZ_SEED=<master> ZCUBE_FUZZ_ITERATIONS=<i + 1>   the run, up to the failing iteration
//!   ZCUBE_FUZZ_ITERATION_SEED=<seed>                          the failing iteration alone
//!
//! `ZCUBE_FUZZ_ITERATIONS=N` makes a long run, which prints its master seed first and a pass line
//! last (a passing test is silent otherwise). The master seed is `ZCUBE_FUZZ_SEED`, else Zig's
//! per-run test seed, else (the test binary run by hand, whose seed is 0) a fresh one from the OS.
//! Native tests only: they read the environment.

const std = @import("std");

const testing = std.testing;

pub const Iteration = *const fn (seed: u64) anyerror!void;

fn number(name: []const u8) ?u64 {
    const text = testing.environ.getPosix(name) orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch std.debug.panic("{s} is not a number", .{name});
}

fn master_seed() u64 {
    if (number("ZCUBE_FUZZ_SEED")) |seed| return seed;
    if (testing.random_seed != 0) return testing.random_seed;
    var bytes: [8]u8 = undefined;
    testing.io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

pub const Failure = struct { index: u64, seed: u64, err: anyerror };

/// The loop of `run`, without the environment or any printing: the first failing iteration.
pub fn first_failure(master: u64, iterations: u64, once: Iteration) ?Failure {
    var generator = std.Random.SplitMix64.init(master);
    for (0..iterations) |index| {
        const seed = generator.next();
        once(seed) catch |err| return .{ .index = index, .seed = seed, .err = err };
    }
    return null;
}

/// Runs `once` for each iteration of the run the environment names, `iterations_default` of them
/// unless `ZCUBE_FUZZ_ITERATIONS` says otherwise, or for one iteration seed alone.
pub fn run(label: []const u8, iterations_default: u64, once: Iteration) !void {
    if (number("ZCUBE_FUZZ_ITERATION_SEED")) |seed| {
        once(seed) catch |err| {
            std.debug.print("{s} failed: {t}; iteration seed {d}\n", .{ label, err, seed });
            return err;
        };
        return;
    }
    const master = master_seed();
    const long = number("ZCUBE_FUZZ_ITERATIONS");
    const iterations = long orelse iterations_default;
    if (long != null) {
        std.debug.print("{s}: seed {d} iterations {d}\n", .{ label, master, iterations });
    }
    if (first_failure(master, iterations, once)) |failure| {
        std.debug.print(
            "{s} failed at iteration {d}: {t}\n" ++
                "  replay the run:       ZCUBE_FUZZ_SEED={d} ZCUBE_FUZZ_ITERATIONS={d}\n" ++
                "  replay the iteration: ZCUBE_FUZZ_ITERATION_SEED={d}\n",
            .{ label, failure.index, failure.err, master, failure.index + 1, failure.seed },
        );
        return failure.err;
    }
    if (long != null) {
        std.debug.print("{s}: PASS seed {d} iterations {d}\n", .{ label, master, iterations });
    }
}

test "fuzz seeds: both printed replays reproduce the failing iteration" {
    // Goal: a failure's two replay commands (the master seed with the iteration count, and the
    // iteration seed alone) run the iteration that failed. Method: a fake iteration fails on
    // the seed that index 3 of master 77 gets; check what `first_failure` reports, then replay it
    // both ways.
    const Fake = struct {
        var bad: u64 = undefined;
        fn once(seed: u64) anyerror!void {
            if (seed == bad) return error.Planted;
        }
    };
    const master: u64 = 77;
    var generator = std.Random.SplitMix64.init(master);
    for (0..3) |_| _ = generator.next();
    Fake.bad = generator.next();
    const failure = first_failure(master, 300, Fake.once).?; // The planted seed is in range.
    try testing.expectEqual(@as(u64, 3), failure.index);
    try testing.expectEqual(Fake.bad, failure.seed);
    try testing.expectError(error.Planted, Fake.once(failure.seed));
    const replay = first_failure(master, failure.index + 1, Fake.once).?; // As above.
    try testing.expectEqual(failure.index, replay.index);
    try testing.expect(first_failure(master, failure.index, Fake.once) == null);
}
