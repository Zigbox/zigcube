//! `zig build zigbox-smoke`: the Zigbox runtime on a real host (C2 slice 1, docs/briefs/c2-1.md,
//! docs/demos/c2.md). Boots Zigbox's pinned Ubuntu guest under QEMU/KVM through the exported
//! `zigbox_vm` module, provisions an ordinary user the way Zigbox's own demos do, copies in
//! `zcube-server`, `zcube-agent` and `zbx`, and runs `ops/zigbox-smoke/guest.sh` stage by stage as
//! that user. The guest script starts a server and `zcube-agent --runtime zigbox`, applies
//! services over HTTP and checks what the kernel shows.
//!
//! **What the stages check** (each prints `ok:` lines, or `FAIL:` and the logs): a 2-replica
//! service from a pulled Alpine image runs with its cgroup limits and no network but `lo`; a
//! `kill -9` of a container is replaced; an agent restart adopts both with no duplicates; a
//! memory hog ends `oom`; a pull whose tree is not the locked one is refused (ZC-E0511); an
//! unknown digest is held (ZBX-E0410); removing a service during its pull leaves the agent up.
//! Then two agents on the one guest, each with a Zigbox store of its own (slice 8): B fetches
//! an image from A as a peer (peer bytes, no registry bytes in its pull record), a second image
//! that overlaps the first moves only the chunks B lacks, an image no peer has is pulled from the
//! registry with a non-empty `fetch.log`, and a fetch past its deadline is killed.
//! **What it does not check:** `pid_limit` (a service cannot set `pids`), `stop` with a grace. See
//! docs/demos/c2.md. A pass is a check, never `demo-c2`.
//!
//! It is slow (minutes) and needs QEMU with KVM, so it does nothing unless `ZCUBE_REAL_HOST=1`.

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
    // The server links libpq and SQLite dynamically; python3 parses the API's JSON in guest.sh.
    .packages = &.{ "uidmap", "passt", "libpq5", "libsqlite3-0", "python3" },
    .sysctls = &.{.{
        .key = "kernel.apparmor_restrict_unprivileged_userns",
        .value = "0",
    }},
};

const cache_dir = ".zig-cache/vm";
const overlay = cache_dir ++ "/overlay-zcube-smoke.qcow2";

/// What a login session of root would set; Zigbox asks that user's systemd bus for a scope per
/// container. The agents run as root, not `cube`: a peer server that is not root cannot open
/// objects owned by a range id that others may not read (docs/demos/c2.md, slice 8). `cube` stays
/// as the owner of the files.
const as_root = "env HOME=/home/cube XDG_RUNTIME_DIR=/run/user/0 " ++
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus ";
/// The stage that gives root its range and its bus, so it has neither yet.
const before_bus = "env HOME=/home/cube ";

/// A file for the guest: the route it is served at, where it goes and its mode.
const Upload = struct { route: []const u8, guest_path: []const u8, mode: []const u8 };

const uploads = [_]Upload{
    .{ .route = "/zcube-agent", .guest_path = "/home/cube/bin/zcube-agent", .mode = "755" },
    .{ .route = "/zcube-server", .guest_path = "/home/cube/bin/zcube-server", .mode = "755" },
    .{ .route = "/zbx", .guest_path = "/home/cube/bin/zbx", .mode = "755" },
    .{ .route = "/guest.sh", .guest_path = "/home/cube/guest.sh", .mode = "644" },
};

/// The stages of guest.sh in order, each with the seconds it may take (KVM; the first start pulls).
const Stage = struct { name: []const u8, timeout_s: u32 };

const stages = [_]Stage{
    .{ .name = "setup_root", .timeout_s = 120 },
    .{ .name = "setup", .timeout_s = 120 },
    .{ .name = "replicas", .timeout_s = 420 },
    .{ .name = "kill", .timeout_s = 150 },
    .{ .name = "restart", .timeout_s = 150 },
    .{ .name = "oom", .timeout_s = 200 },
    .{ .name = "refusals", .timeout_s = 260 },
    .{ .name = "scale0", .timeout_s = 150 },
    // Slice 8: a second agent with a Zigbox store of its own fetches from the first.
    .{ .name = "peers_prep", .timeout_s = 560 },
    .{ .name = "peers_up", .timeout_s = 120 },
    .{ .name = "peers_fetch", .timeout_s = 560 },
    .{ .name = "peers_fallback", .timeout_s = 560 },
};

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
    if (args.len != 5) return usage(out);
    var bodies: [uploads.len][]const u8 = undefined;
    for (&bodies, args[1..]) |*body, path| {
        body.* = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited);
    }
    var files: [uploads.len]vm.Route = undefined;
    for (&files, uploads, bodies) |*file, upload, body| {
        file.* = .{ .path = upload.route, .body = body };
    }

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
        .files = &files,
    });
    defer session.deinit();
    try session.provision(config.hostname, false);
    const passed = try run_guest(&session, out);
    try session.shutdown();
    if (!passed) return 1;
    try out.writeAll("zigbox-smoke: passed: every stage above\n");
    try out.writeAll("zigbox-smoke: NOT run: pid_limit, stop with a grace (docs/demos/c2.md)\n");
    return 0;
}

/// Copies the files in and runs the stages; false (after printing why) at the first failure.
fn run_guest(session: *vm.Session, out: *std.Io.Writer) !bool {
    const timeout = vm.limits.command_timeout_kvm_s;
    const made = try session.run("mkdir -p /home/cube/bin", timeout);
    if (made.status != 0) return failed(out, "mkdir in the guest failed");
    for (uploads) |upload| {
        _ = try session.copy_in(.{
            .route = upload.route,
            .guest_path = upload.guest_path,
            .owner = "cube:cube",
            .mode = upload.mode,
        });
    }
    var command: [vm.limits.command_bytes_max]u8 = undefined;
    for (stages) |stage| {
        const prefix = if (std.mem.eql(u8, stage.name, "setup_root")) before_bus else as_root;
        const line = try std.fmt.bufPrint(&command, "{s}sh /home/cube/guest.sh {s}", .{
            prefix, stage.name,
        });
        try out.print("zigbox-smoke: stage {s}\n", .{stage.name});
        const result = try session.run(line, stage.timeout_s);
        try out.print("{s}\n", .{result.output});
        if (result.status != 0) {
            try out.print("zigbox-smoke: FAILED: stage {s} exited {d}\n", .{
                stage.name, result.status,
            });
            return false;
        }
    }
    return true;
}

fn enabled(init: std.process.Init) bool {
    const value = init.minimal.environ.getPosix("ZCUBE_REAL_HOST") orelse return false;
    return std.mem.eql(u8, value, "1");
}

fn usage(out: *std.Io.Writer) !u8 {
    try out.writeAll("usage: zigbox_smoke <zcube-agent> <zcube-server> <zbx> <guest.sh>\n");
    return 2;
}

fn failed(out: *std.Io.Writer, what: []const u8) !bool {
    try out.print("zigbox-smoke: FAILED: {s}\n", .{what});
    return false;
}
