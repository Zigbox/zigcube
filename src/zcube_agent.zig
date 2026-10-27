//! `zcube-agent`: the node agent. Placeholder while the slice is built: the supervisor mode.

const std = @import("std");
const build_options = @import("build_options");
const constants = @import("constants.zig");
const fake_supervisor = @import("fake_supervisor.zig");

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch return constants.exit_environment;
    if (args.len == 3 and std.mem.eql(u8, args[1], "supervise")) {
        return fake_supervisor.run(init, args[2]);
    }
    const line = "zcube-agent " ++ build_options.version ++ "\n";
    std.Io.File.stdout().writeStreamingAll(init.io, line) catch return constants.exit_environment;
    return constants.exit_ok;
}
