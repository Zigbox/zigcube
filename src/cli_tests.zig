//! Test root of `zcube` alone (`zig build test-cli`): the tests of the command line's own files,
//! without the server's client libraries (SQLite, libpq) or the console's files. It is what the
//! macOS job runs, where only the command line is built (docs/macos.md); `zig build test` runs
//! the same tests on Linux as part of `src/tests.zig`. `cli_test.zig` is left out: it runs the
//! command line against a real `zcube-server`, which needs SQLite and the console.

test {
    _ = @import("cli.zig");
    _ = @import("cli_allocations.zig");
    _ = @import("cli_args.zig");
    _ = @import("cli_commands.zig");
    _ = @import("cli_data.zig");
    _ = @import("cli_env.zig");
    _ = @import("cli_get.zig");
    _ = @import("cli_http.zig");
    _ = @import("cli_job.zig");
    _ = @import("cli_job_args.zig");
    _ = @import("cli_job_view.zig");
    _ = @import("cli_local.zig");
    _ = @import("cli_report.zig");
    _ = @import("cli_service.zig");
    _ = @import("cli_stats.zig");
    _ = @import("cli_view.zig");
    _ = @import("cli_golden.zig");
}
