//! Test root: pulls every module's tests into one binary (`zig build test`).

test {
    _ = @import("constants.zig");
    _ = @import("text.zig");
    _ = @import("test_util.zig");
    _ = @import("diag/codes.zig");
    _ = @import("diag.zig");
    _ = @import("diagnostic.zig");
}
