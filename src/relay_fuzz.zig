//! A seeded fuzzer for the relay's copy loop (`relay_pump.zig`): a source of random length is
//! copied to a sink with random short reads and short writes, in random order, under a random
//! byte limit. The property: the sink gets exactly the source's first `min(length, limit)` bytes
//! in order, a read is never asked for more than the room under the limit, an end of input is
//! never lost behind buffered bytes, and the run ends as `finished` (the source ended under the
//! limit) or `exhausted` (it did not). Seeds and replay are in `fuzz_seeds.zig`.

const std = @import("std");
const constants = @import("constants.zig");
const Pipe = @import("relay_pump.zig").Pipe;
const seeds = @import("fuzz_seeds.zig");

const iterations_default = 300;
const source_bytes_max = 3 * constants.relay_buffer_bytes;
const steps_max = 4 * source_bytes_max;

fn copy_once(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var source: [source_bytes_max]u8 = undefined;
    random.bytes(&source);
    const length = random.uintAtMost(usize, source.len);
    const limit = random.intRangeAtMost(u64, 1, source.len + 64);
    var sink: [source_bytes_max]u8 = undefined;
    var written: usize = 0;
    var read: usize = 0;
    var pipe: Pipe = .{ .limit = limit };
    var steps: usize = 0;
    while (!pipe.finished() and !pipe.exhausted()) : (steps += 1) {
        if (steps == steps_max) return error.NoProgress;
        const can_read = pipe.wants_read();
        const can_write = pipe.wants_write();
        if (!can_read and !can_write) return error.Stuck;
        if (can_write and (!can_read or random.boolean())) {
            const offered = pipe.write_from();
            const count = random.intRangeAtMost(usize, 1, offered.len);
            @memcpy(sink[written..][0..count], offered[0..count]);
            written += count;
            pipe.drained(count);
        } else {
            const into = pipe.read_into();
            if (into.len > limit - written) return error.ReadPastLimit;
            const count = random.uintAtMost(usize, @min(into.len, length - read));
            const ended = read == length;
            @memcpy(into[0..count], source[read..][0..count]);
            read += count;
            // A read of nothing is the end of the source, so only say so when it is.
            if (count == 0 and !ended) continue;
            pipe.fed(count);
        }
    }
    const expected: usize = @intCast(@min(length, limit));
    if (written != expected or pipe.moved != expected) return error.WrongLength;
    if (!std.mem.eql(u8, sink[0..written], source[0..written])) return error.WrongBytes;
    if (length < limit and !pipe.finished()) return error.EndLost;
    if (length >= limit and !pipe.exhausted()) return error.LimitNotSaid;
}

test "fuzz: a relayed stream arrives whole and in order, or stops at its limit" {
    // Goal: no byte dropped, repeated or reordered, no read past the limit, no end of input lost.
    // Method: random lengths, limits, short reads and short writes; seeds as in fuzz_seeds.zig.
    try seeds.run("relay copy fuzz", iterations_default, copy_once);
}
