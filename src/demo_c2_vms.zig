//! demo-c2's machines: four QEMU guests through Zigbox's exported `zigbox_vm` module, one per
//! node, booted together at the start (node4's agent joins only in step 4). Each guest forwards
//! one host port, H_i on 127.0.0.1, to its peer server (port 7071), and its agent advertises
//! `10.0.2.2:H_i`, so peer traffic goes guest -> host -> guest (docs/demos/c2.md, "demo-c2").
//!
//! A session moves only while it is pumped, so every wait of the demo pumps all four
//! (`pump_all`): their consoles are read and their seed servers answer.

const std = @import("std");
const assert = std.debug.assert;
const vm = @import("zigbox_vm");

pub const count = 4;
pub const names = [count][]const u8{ "node1", "node2", "node3", "node4" };

/// Where each guest's peer server listens; the host forwards H_i to it.
pub const peer_port_guest: u16 = 7071;

const cache_dir = ".zig-cache/vm";

/// What a login session of `cube` would set (as src/zigbox_smoke.zig does).
pub const as_cube = "runuser -u cube -- env HOME=/home/cube XDG_RUNTIME_DIR=/run/user/1000 " ++
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus ";

pub const script = "/home/cube/guest.sh";

const configs = configs: {
    var list: [count]vm.Config = undefined;
    for (&list, 0..) |*config, index| {
        config.* = .{
            .hostname = std.fmt.comptimePrint("demo-c2-{d}", .{index + 1}),
            .instance_id = std.fmt.comptimePrint("iid-demo-c2-{d}", .{index + 1}),
            .user = .{
                .name = "cube",
                .uid = 1000,
                .subid_start = 100000,
                .subid_count = 65536,
                .linger = true,
            },
            // nftables for step 3's rule on guest 3; uidmap and passt as zigbox-smoke, for
            // the rootless containers of Zigbox.
            .packages = &.{ "uidmap", "passt", "nftables" },
            .sysctls = &.{.{
                .key = "kernel.apparmor_restrict_unprivileged_userns",
                .value = "0",
            }},
        };
    }
    break :configs list;
};

/// A file for the guests: the route it is served at, where it goes and its mode.
pub const Upload = struct { route: []const u8, guest_path: []const u8, mode: []const u8 };

pub const uploads = [_]Upload{
    .{ .route = "/zcube-agent", .guest_path = "/home/cube/bin/zcube-agent", .mode = "755" },
    .{ .route = "/zbx", .guest_path = "/home/cube/bin/zbx", .mode = "755" },
    .{ .route = "/guest.sh", .guest_path = script, .mode = "644" },
};

pub const Guests = struct {
    sessions: [count]vm.Session = undefined,
    started: [count]bool = @splat(false),
    /// H_i: the host port forwarded to guest i's peer server.
    peer_ports: [count]u16,
    files: [uploads.len]vm.Route = undefined,
    forwards: [count][1]vm.Forward = undefined,
    overlays: [count][]const u8 = undefined,
    user_data: [count][vm.limits.user_data_bytes_max]u8 = undefined,
    meta_data: [count][vm.limits.meta_data_bytes_max]u8 = undefined,
    out: *std.Io.Writer,

    /// Boots all four guests at once, then provisions each and copies the files in.
    /// `bodies` are the files of `uploads`, in order; they must outlive the guests.
    pub fn boot(
        guests: *Guests,
        init: std.process.Init,
        bodies: [uploads.len][]const u8,
    ) !void {
        const arena = init.arena.allocator();
        for (&guests.files, uploads, bodies) |*file, upload, body| {
            file.* = .{ .path = upload.route, .body = body };
        }
        const accel = try vm.accel.choose("auto", vm.accel.kvm_usable(init.io));
        const base = try vm.image.ensure_pin(init, cache_dir, guests.out, vm.image.ubuntu_noble);
        for (0..count) |index| {
            guests.overlays[index] = try std.fmt.allocPrint(
                arena,
                cache_dir ++ "/overlay-demo-c2-{d}.qcow2",
                .{index + 1},
            );
            try vm.image.make_overlay(init, base, guests.overlays[index]);
            guests.forwards[index] = .{.{
                .host_port = guests.peer_ports[index],
                .guest_port = peer_port_guest,
            }};
            try guests.sessions[index].start(init, guests.out, guests.overlays[index], accel, .{
                .user_data = try vm.cloud_init.render_user_data(
                    &configs[index],
                    &guests.user_data[index],
                ),
                .meta_data = try vm.cloud_init.render_meta_data(
                    &configs[index],
                    &guests.meta_data[index],
                ),
                .files = &guests.files,
                .forwards = &guests.forwards[index],
            });
            guests.started[index] = true;
        }
        try guests.wait_booted();
        for (0..count) |index| try guests.prepare(index);
    }

    /// Pumps every guest until each console shows cloud-init's ready marker, so the four boot
    /// in parallel; `provision` then finds the marker at once.
    fn wait_booted(guests: *Guests) !void {
        const deadline = vm.now_ms() + @as(u64, vm.limits.boot_timeout_kvm_s) * 1000 * 2;
        while (vm.now_ms() < deadline) {
            var ready: u32 = 0;
            for (&guests.sessions) |*session| {
                const text = session.console[0..session.console_len];
                if (std.mem.indexOf(u8, text, vm.cloud_init.ready_marker) != null) ready += 1;
                if (session.qemu_exited) return error.QemuExited;
            }
            if (ready == count) return;
            try guests.pump_all(50);
        }
        return error.BootTimeout;
    }

    fn prepare(guests: *Guests, index: usize) !void {
        const session = &guests.sessions[index];
        try session.provision(configs[index].hostname, false);
        const timeout = vm.limits.command_timeout_kvm_s;
        const made = try session.run("runuser -u cube -- mkdir -p /home/cube/bin", timeout);
        if (made.status != 0) return error.GuestSetupFailed;
        for (uploads) |upload| {
            const copied = try session.copy_in(.{
                .route = upload.route,
                .guest_path = upload.guest_path,
                .owner = "cube:cube",
                .mode = upload.mode,
            });
            if (copied.status != 0) return error.GuestSetupFailed;
        }
    }

    /// One round over every guest: console output, the seed server, `ms` of waiting each.
    pub fn pump_all(guests: *Guests, ms: u32) !void {
        for (&guests.sessions, guests.started) |*session, started| {
            if (started) try session.pump(ms);
        }
    }

    /// Runs `guest.sh <arguments>` as `cube` on guest `index`.
    pub fn cube(
        guests: *Guests,
        index: u32,
        arguments: []const u8,
        timeout_s: u32,
    ) !vm.Session.Result {
        var line: [vm.limits.command_bytes_max]u8 = undefined;
        const command = try std.fmt.bufPrint(&line, as_cube ++ "sh " ++ script ++ " {s}", .{
            arguments,
        });
        return guests.sessions[index].run(command, timeout_s);
    }

    /// Runs `guest.sh <arguments>` as root on guest `index`.
    pub fn root(
        guests: *Guests,
        index: u32,
        arguments: []const u8,
        timeout_s: u32,
    ) !vm.Session.Result {
        var line: [vm.limits.command_bytes_max]u8 = undefined;
        const command = try std.fmt.bufPrint(&line, "sh " ++ script ++ " {s}", .{arguments});
        return guests.sessions[index].run(command, timeout_s);
    }

    /// Powers every started guest off; a guest that does not stop is killed by `deinit`.
    pub fn shutdown(guests: *Guests) void {
        for (&guests.sessions, guests.started) |*session, started| {
            if (!started) continue;
            if (session.qemu_exited) continue;
            session.shutdown() catch {}; // `deinit` kills what did not stop.
        }
    }

    pub fn deinit(guests: *Guests, io: std.Io) void {
        for (&guests.sessions, &guests.started, guests.overlays) |*session, *started, overlay| {
            if (!started.*) continue;
            session.deinit();
            started.* = false;
            std.Io.Dir.cwd().deleteFile(io, overlay) catch {}; // A leftover is replaced.
        }
    }
};

comptime {
    assert(uploads.len + vm.limits.seed_routes <= vm.limits.http_routes_max);
    assert(names.len == count);
}
