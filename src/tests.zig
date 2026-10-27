//! Test root: pulls every module's tests into one binary (`zig build test`).

test {
    _ = @import("constants.zig");
    _ = @import("text.zig");
    _ = @import("test_util.zig");
    _ = @import("clock.zig");
    _ = @import("diag/codes.zig");
    _ = @import("diag.zig");
    _ = @import("store.zig");
    _ = @import("store_failures.zig");
    _ = @import("store_memory.zig");
    _ = @import("store_sqlite.zig");
    _ = @import("pq.zig");
    _ = @import("store_postgres.zig");
    _ = @import("runtime.zig");
    _ = @import("records.zig");
    _ = @import("core.zig");
    _ = @import("server_arena.zig");
    _ = @import("server_config.zig");
    _ = @import("server_http.zig");
    _ = @import("server_static.zig");
    _ = @import("server.zig");
    _ = @import("server_test.zig");
    _ = @import("tidy.zig");
}
