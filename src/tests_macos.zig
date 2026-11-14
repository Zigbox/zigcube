//! The unit tests that build on macOS: the CLI's own, the diagnostics and the macOS release tool.
//! The agent, the server, the stores and the runtimes need Linux and are not here; `zig build
//! test` runs every test, these included, on Linux. `zig build test-macos` runs this root (the
//! `mac-test` job, on a Mac); `zig build mac-bin` compiles it for both macOS architectures.

test {
    _ = @import("constants.zig");
    _ = @import("text.zig");
    _ = @import("clock.zig");
    _ = @import("diag/codes.zig");
    _ = @import("diag.zig");
    _ = @import("cli.zig");
    _ = @import("cli_allocations.zig");
    _ = @import("cli_args.zig");
    _ = @import("cli_commands.zig");
    _ = @import("cli_data.zig");
    _ = @import("cli_env.zig");
    _ = @import("cli_get.zig");
    _ = @import("cli_http.zig");
    _ = @import("cli_local.zig");
    _ = @import("cli_report.zig");
    _ = @import("cli_service.zig");
    _ = @import("cli_view.zig");
    _ = @import("cli_golden.zig");
    _ = @import("mac_release.zig");
}
