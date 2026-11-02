//! `zig build zigbox-smoke`: the Zigbox runtime on a real host (C2 slice 1, docs/briefs/c2-1.md).
//! Boots Zigbox's pinned Ubuntu guest under QEMU through the exported `zigbox_vm` module,
//! provisions an ordinary user the way Zigbox's own demos do, copies in `zcube-agent` and runs it
//! with `--runtime zigbox`.
//!
//! **What it checks today:** the agent's own build runs on the guest's glibc, `--runtime zigbox`
//! passes its host preflight (no ZC-E0512) and the agent stays up until `timeout` ends it. **What
//! it does not check:** a container started from a pulled image. That needs a registry the
//! guest can reach and a service whose digest is locked against it; slice 1 leaves it to the
//! supervisor's manual run (docs/agent.md). The result says so rather than passing silently.
//!
//! It is slow (minutes) and needs QEMU, so it does nothing unless `ZCUBE_REAL_HOST=1`.

const std = @import("std");
const vm = @import("zigbox_vm");

const config: vm.Config = .{
    .hostname = "zigcube-smoke",
    .instance_id = "iid-zigcube-smoke",
    .user = .{
        .name = "cube",
        .uid = 1000,
        .subid_start = 100000,
        .subid_count = 65536,
        .linger = true,
    },
    .packages = &.{ "uidmap", "passt" },
    .sysctls = &.{.{
        .key = "kernel.apparmor_restrict_unprivileged_userns",
        .value = "0",
    }},
};

const cache_dir = ".zig-cache/vm";
const overlay = cache_dir ++ "/overlay-zcube-smoke.qcow2";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {}; // Nowhere else to report it.

    if (!enabled(init)) {
        try out.writeAll("zigbox-smoke: skipped (set ZCUBE_REAL_HOST=1; it boots a QEMU guest)\n");
        return 0;
    }
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return usage(out);
    const agent = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .unlimited);

    const accel = try vm.accel.choose("auto", vm.accel.kvm_usable(init.io));
    const base = try vm.image.ensure_pin(init, cache_dir, out, vm.image.ubuntu_noble);
    try vm.image.make_overlay(init, base, overlay);
    defer std.Io.Dir.cwd().deleteFile(init.io, overlay) catch {}; // A leftover is replaced.

    var user_data: [vm.limits.user_data_bytes_max]u8 = undefined;
    var meta_data: [vm.limits.meta_data_bytes_max]u8 = undefined;
    var session: vm.Session = undefined;
    try session.start(init, out, overlay, accel, .{
        .user_data = try vm.cloud_init.render_user_data(&config, &user_data),
        .meta_data = try vm.cloud_init.render_meta_data(&config, &meta_data),
        .files = &.{.{ .path = "/zcube-agent", .body = agent }},
    });
    defer session.deinit();
    try session.provision(config.hostname, false);
    _ = try session.copy_in(.{
        .route = "/zcube-agent",
        .guest_path = "/home/cube/zcube-agent",
        .owner = "cube:cube",
        .mode = "755",
    });
    const timeout = vm.limits.command_timeout_kvm_s;
    const version = try session.run("runuser -u cube -- /home/cube/zcube-agent --version", timeout);
    if (version.status != 0) return failed(out, "zcube-agent --version failed in the guest");

    // The agent has no server to reach: it must still pass its preflight and keep trying, so
    // `timeout` (exit 124) ends it. ZC-E0512 would end it at once with another status.
    const run_agent = "runuser -u cube -- sh -c 'mkdir -p /home/cube/state && timeout 5 " ++
        "/home/cube/zcube-agent --runtime zigbox --node smoke --server 10.0.2.2:1 " ++
        "--state-dir /home/cube/state --cpu-millis 1000 --memory-bytes 1073741824'";
    const agent_run = try session.run(run_agent, timeout);
    if (agent_run.status != 124) return failed(out, "the agent did not stay up under zigbox");
    try session.shutdown();
    try out.writeAll("zigbox-smoke: passed: agent starts on a real host with --runtime zigbox\n");
    try out.writeAll("zigbox-smoke: NOT run: a container from a pulled image\n");
    return 0;
}

fn enabled(init: std.process.Init) bool {
    const value = init.minimal.environ.getPosix("ZCUBE_REAL_HOST") orelse return false;
    return std.mem.eql(u8, value, "1");
}

fn usage(out: *std.Io.Writer) !u8 {
    try out.writeAll("usage: zigbox_smoke <zcube-agent>\n");
    return 2;
}

fn failed(out: *std.Io.Writer, what: []const u8) !u8 {
    try out.print("zigbox-smoke: FAILED: {s}\n", .{what});
    return 1;
}
