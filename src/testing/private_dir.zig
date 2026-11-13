//! Test-only. A server's state directory must not be writable by group or others (ZC-E0806,
//! docs/peer.md), and `std.testing.tmpDir` makes its directory under the runner's umask, which
//! is 002 for a user with a private group. A test that starts a server calls `state_dir` first,
//! so no test depends on the umask it runs under.

const std = @import("std");
const config_mod = @import("../server_config.zig");
const diag_mod = @import("../diag.zig");
const server_mod = @import("../server.zig");

/// Sets the state directory `config` names (or implies) to 0700. One that does not exist yet
/// is left to the server, and a configuration with none (memory, or Postgres without a state
/// directory) is left alone.
pub fn state_dir(io: std.Io, config: config_mod.Config) !void {
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const path = server_mod.Server.state_path(config, &diag) orelse return;
    if (diag.code != null) return;
    const cwd = std.Io.Dir.cwd();
    cwd.setFilePermissions(io, path, .fromMode(0o700), .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
