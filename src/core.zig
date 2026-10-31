//! The control-plane core: the modules that must stay free of the shell, and the two checks that
//! hold them to it (docs/wasm.md). The core is controllers, scheduler and API handlers written as
//! functions over `Store`, `Runtime` and `Clock`, plus the types and diagnostics they share. The
//! shell is what supplies those three and everything else a process needs: HTTP, Postgres and
//! SQLite, threads, files, the real clock, `std.Io`.
//!
//! The rule is checked by compiling, not by reading: `zig build wasm` builds these modules for
//! `wasm32-freestanding`, a target with no libc, no OS, no threads and no `std.Io`, so an import
//! of any of them fails the build; `zig build wasm-test` runs the modules' own unit tests under
//! WASI. A module joins the core by being listed here, and nothing else changes.

const std = @import("std");

pub const modules = .{
    @import("agent.zig"),
    @import("agent_api.zig"),
    @import("agent_client.zig"),
    @import("agent_loop.zig"),
    @import("agent_records.zig"),
    @import("agent_state.zig"),
    @import("api.zig"),
    @import("apply.zig"),
    @import("clock.zig"),
    @import("compare_sets.zig"),
    @import("controller.zig"),
    @import("console_sim.zig"),
    @import("constants.zig"),
    @import("core_smoke.zig"),
    @import("diag.zig"),
    @import("diag/codes.zig"),
    @import("records.zig"),
    @import("replica_controller.zig"),
    @import("runtime_codes.zig"),
    @import("retention.zig"),
    @import("runtime.zig"),
    @import("sim_c0.zig"),
    @import("sim_clock.zig"),
    @import("sim_cluster.zig"),
    @import("sim_net.zig"),
    @import("sim_node.zig"),
    @import("sim_runtime.zig"),
    @import("sim_store.zig"),
    @import("sim_world.zig"),
    @import("store.zig"),
    @import("store_failures.zig"),
    @import("store_memory.zig"),
    @import("test_util.zig"),
    @import("testing/history.zig"),
    @import("text.zig"),
    @import("why.zig"),
    @import("writers.zig"),
};

/// References every public declaration of every core module, and of the types they declare, so
/// that all of it is analysed and generated and not only what a scenario reaches. Zig analyses
/// only what is referenced, so a banned call inside a function nobody calls would otherwise go
/// unseen. Two levels are followed: a module, then the types declared in it.
pub fn reference_all() void {
    // Walking every declaration of every module takes more comptime branches than the default.
    @setEvalBranchQuota(1_000_000);
    inline for (modules) |module| reference_declarations(module);
}

fn reference_declarations(comptime container: type) void {
    inline for (comptime std.meta.declarations(container)) |declaration| {
        const value = @field(container, declaration);
        reference_value(value);
        if (@TypeOf(value) == type) {
            switch (@typeInfo(value)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => {
                    inline for (comptime std.meta.declarations(value)) |inner| {
                        reference_value(@field(value, inner));
                    }
                },
                else => {},
            }
        }
    }
}

/// Takes the address of a function, so that it is analysed and generated. Generic functions and
/// non-functions have no address to take and are skipped.
fn reference_value(comptime value: anytype) void {
    const T = @TypeOf(value);
    if (T == type) return;
    if (@typeInfo(T) != .@"fn") return;
    if (@typeInfo(T).@"fn".is_generic) return;
    _ = &value;
}

test "every core module's tests are in this root" {
    // Goal: `zig build wasm-test` compiles this file for WASI and runs it, so the unit tests of
    // the core modules run on a 32-bit address space with a single thread. Method: import each
    // module, which brings its tests in.
    inline for (modules) |module| _ = module;
}

test "the single-threaded store conformance tests are in this root" {
    // Goal: the memory store's semantics are checked in the environment the browser uses.
    // Method: `store_conformance_single.zig` has no thread and runs against `MemoryStore`
    // (`conformance_options` names the memory backend in this build); importing it brings its
    // tests into this root, so `zig build wasm-test` runs them under WASI.
    _ = @import("store_conformance_single.zig");
}

test "the controllers' tests are in this root" {
    // Goal: the controllers' tests run under WASI too. Method: import them (they use only the
    // memory store, a manual clock and the testing allocator).
    _ = @import("replica_controller_test.zig");
    _ = @import("api_test.zig");
    _ = @import("agent_api_test.zig");
}
