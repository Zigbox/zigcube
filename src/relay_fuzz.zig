//! A seeded fuzzer for the relay's copy loop (`relay_pump.zig`): a source of random length is
//! copied to a sink with random short reads and short writes, in random order, under a random
//! byte limit. The property: the sink gets exactly the source's first `min(length, limit)` bytes
//! in order, a read is never asked for more than the room under the limit, an end of input is
//! never lost behind buffered bytes, and the run ends as `finished` (the source ended under the
//! limit) or `exhausted` (it did not). Seeds and replay are in `fuzz_seeds.zig`.

const std = @import("std");
const constants = @import("constants.zig");
const Pipe = @import("relay_pump.zig").Pipe;
const relay = @import("relay.zig");
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

// ---- The copy loop over fake sockets ----------------------------------------------------------

const wire_bytes_max = 2 * constants.relay_buffer_bytes + 100;

/// Two fake sockets, 0 (the job's) and 1 (the upstream's). Each has the bytes its peer will send
/// (`incoming`, with `arrived` of them readable so far) and collects what is written to it. Reads
/// and writes return random short counts or would-block; a socket whose peer's data is all given
/// reads an end. `faulty` makes the loop pass an end on to the wrong socket.
fn FakeSys(comptime faulty: bool) type {
    return struct {
        const Self = @This();
        pub const shutdown_wrong_end = faulty;

        state: *State,

        const State = struct {
            random: std.Random,
            incoming: [2][wire_bytes_max]u8 = undefined,
            length: [2]u32 = .{ 0, 0 },
            read_count: [2]u32 = .{ 0, 0 },
            received: [2][wire_bytes_max]u8 = undefined,
            written: [2]u32 = .{ 0, 0 },
            shut: [2]bool = .{ false, false },
            broken: ?anyerror = null,
        };

        pub fn read(self: Self, fd: i32, buffer: []u8) relay.Moved {
            const state = self.state;
            const side: usize = @intCast(fd);
            if (state.random.uintLessThan(u8, 4) == 0) return .again;
            const left = state.length[side] - state.read_count[side];
            const count = state.random.uintAtMost(u32, @intCast(@min(buffer.len, left)));
            if (count == 0 and left > 0) return .again;
            @memcpy(buffer[0..count], state.incoming[side][state.read_count[side]..][0..count]);
            state.read_count[side] += count;
            return .{ .count = count };
        }

        pub fn write(self: Self, fd: i32, bytes: []const u8) relay.Moved {
            const state = self.state;
            const side: usize = @intCast(fd);
            if (state.random.uintLessThan(u8, 4) == 0) return .again;
            const count = state.random.intRangeAtMost(u32, 1, @intCast(bytes.len));
            @memcpy(state.received[side][state.written[side]..][0..count], bytes[0..count]);
            state.written[side] += count;
            return .{ .count = count };
        }

        pub fn shutdown_write(self: Self, fd: i32) void {
            const state = self.state;
            const side: usize = @intCast(fd);
            // The end must come after every byte the other socket sent, as far as it was allowed.
            if (state.written[side] < state.length[1 - side]) state.broken = error.EndBeforeBytes;
            state.shut[side] = true;
        }
    };
}

fn lanes_once(comptime faulty: bool, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const Fake = FakeSys(faulty);
    var state: Fake.State = .{ .random = random };
    for (0..2) |side| {
        random.bytes(&state.incoming[side]);
        state.length[side] = random.uintAtMost(u32, wire_bytes_max);
    }
    const limit = random.intRangeAtMost(u64, 1, wire_bytes_max + 64);
    var inbound = relay.Lane.init(0, 1, limit);
    var outbound = relay.Lane.init(1, 0, limit);
    const sys: Fake = .{ .state = &state };
    var result: relay.Round = .quiet;
    var steps: usize = 0;
    while (result != .clean and result != .byte_bound) : (steps += 1) {
        if (steps == 100_000) return error.NoProgress;
        result = relay.round(sys, &inbound, &outbound);
        if (result == .failed) return error.Failed;
    }
    if (state.broken) |err| return err;
    for (0..2) |side| {
        // What a socket received is a prefix of what its peer sent, whole if it fits the limit.
        const peer = 1 - side;
        const expected: usize = @intCast(@min(state.length[peer], limit));
        if (state.written[side] > expected) return error.TooMany;
        const got = state.received[side][0..state.written[side]];
        if (!std.mem.eql(u8, got, state.incoming[peer][0..got.len])) return error.WrongBytes;
        if (result == .clean and state.written[side] != expected) return error.Short;
        if (result == .clean and !state.shut[side]) return error.EndLost;
    }
}

fn lanes_sound(seed: u64) !void {
    return lanes_once(false, seed);
}

test "fuzz: the copy loop over short counts and would-block moves every byte and every end" {
    // Goal: the loop's own order (write, read, write; the end passed on after the bytes) holds
    // under short reads, short writes and would-block. Method: two fake sockets with random data
    // and a random limit; `round` until clean or bound; check order, content and ends.
    try seeds.run("relay lanes fuzz", iterations_default, lanes_sound);
}

fn lanes_faulty(seed: u64) !void {
    return lanes_once(true, seed);
}

test "the lanes fuzzer has teeth: an end passed on to the wrong socket fails it" {
    // The loop is built with `shutdown_wrong_end`; the fuzzer must see it.
    if (seeds.first_failure(1, 2000, lanes_faulty) == null) return error.FuzzerHasNoTeeth;
}
