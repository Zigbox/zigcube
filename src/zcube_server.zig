//! `zcube-server`: a stub until its milestone lands. It prints its name and version and exits.

const std = @import("std");
const build_options = @import("build_options");
const constants = @import("constants.zig");

pub fn main(init: std.process.Init) u8 {
    const line = "zcube-server " ++ build_options.version ++ "\n";
    std.Io.File.stdout().writeStreamingAll(init.io, line) catch return constants.exit_environment;
    return constants.exit_ok;
}
