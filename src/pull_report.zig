//! The pull record a node publishes to `/pulls` (C2 slice 8, Z5): `containers/<name>/pull.json`,
//! a `records.Pull`. Two writers share this file: `zcube-agent fetch --report` (a tree from
//! peers) and the Zigbox supervisor (a tree from the registry, by Zigbox's own `pull`). Shell
//! code: files.
//!
//! Units. `registry_bytes` is the length of each blob `pull` downloaded or resumed, as Zigbox
//! reports it (the compressed layer, and a resumed blob counts whole). `cached_bytes` is whatever
//! the node already held: store chunk bytes for a peer fetch, the length of each cached blob for
//! a pull. The two are not comparable byte for byte; /pulls shows them as separate figures.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const records = @import("records.zig");

pub const Blob = zigbox.pull.Result.Blob;

pub const Tally = struct {
    registry_bytes: u64 = 0,
    cached_bytes: u64 = 0,
};

/// Sorts a pull's blobs by where their bytes came from.
pub fn tally(blobs: []const Blob) Tally {
    var sums: Tally = .{};
    for (blobs) |blob| switch (blob.outcome) {
        .downloaded, .resumed => sums.registry_bytes += blob.bytes,
        .cached => sums.cached_bytes += blob.bytes,
    };
    return sums;
}

/// Writes `record` to `path` through a temporary file and a rename, so the agent never reads half
/// of it. An error if it could not be written (the caller says which): the statistics are lost,
/// nothing else.
pub fn write(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    record: records.Pull,
) !void {
    assert(path.len > 0);
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    std.json.Stringify.value(record, .{}, &text.writer) catch |err| return err;
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = std.fmt.bufPrint(&name_buffer, "{s}.tmp", .{path}) catch |err| return err;
    const dir = std.Io.Dir.cwd();
    dir.writeFile(io, .{ .sub_path = temporary, .data = text.written() }) catch |err| return err;
    dir.rename(temporary, dir, path, io) catch |err| return err;
}

const testing = std.testing;

test "tally sorts a pull's blobs into registry and cached bytes" {
    const blobs = [_]Blob{
        .{ .digest = undefined, .bytes = 100, .outcome = .downloaded },
        .{ .digest = undefined, .bytes = 7, .outcome = .cached },
        .{ .digest = undefined, .bytes = 30, .outcome = .resumed },
    };
    const sums = tally(&blobs);
    try testing.expectEqual(@as(u64, 130), sums.registry_bytes);
    try testing.expectEqual(@as(u64, 7), sums.cached_bytes);
    try testing.expectEqual(@as(u64, 0), tally(&.{}).registry_bytes);
}

test "write leaves a pull record that reads back, and no temporary file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd: [512]u8 = undefined;
    const length = try std.process.currentPath(testing.io, &cwd);
    var path_buffer: [768]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/.zig-cache/tmp/{s}/pull.json", .{
        cwd[0..length], tmp.sub_path,
    });
    const record: records.Pull = .{ .node = "n1", .tree = "b3:ab", .registry_bytes = 42 };
    try write(testing.allocator, testing.io, path, record);
    const text = try tmp.dir.readFileAlloc(
        testing.io,
        "pull.json",
        testing.allocator,
        .limited(4096),
    );
    defer testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(records.Pull, testing.allocator, text, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u64, 42), parsed.value.registry_bytes);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "pull.json.tmp", .{}));
    try testing.expectError(
        error.FileNotFound,
        write(testing.allocator, testing.io, "/nonexistent-dir/pull.json", record),
    );
}
