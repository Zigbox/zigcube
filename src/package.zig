//! The `zigbox_package` module: write `.deb` and `.rpm` packages and the apt and dnf repositories
//! around them, reproducibly, with the standard library alone.
//!
//! Copied from Zigbox v0.5.0 (4b3f6f9), `src/package.zig`; adapted for Zigcube.
pub const model = @import("package/model.zig");
pub const deb = @import("package/deb.zig");
pub const rpm = @import("package/rpm.zig");
pub const apt = @import("package/apt.zig");
pub const dnf = @import("package/dnf.zig");
pub const openpgp = @import("package/openpgp.zig");

test {
    _ = @import("package/model.zig");
    _ = @import("package/archive.zig");
    _ = @import("package/deb.zig");
    _ = @import("package/rpm.zig");
    _ = @import("package/openpgp.zig");
    _ = @import("package/apt.zig");
    _ = @import("package/dnf.zig");
}
