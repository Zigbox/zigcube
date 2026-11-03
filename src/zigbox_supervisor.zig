//! The supervisor of one Zigbox container: `zcube-agent supervise-zigbox <launch directory>`.
//! C2 slice 1. Shell code: a process of its own that pulls, starts, waits and signals.
//!
//! It is what `fake_supervisor.zig` is for `FakeRuntime`, and for the same reason: only the
//! process that starts a container can wait for it, and Zigbox's `start` and `pull` need a
//! caller that is the only thread of its process. It takes the launch directory's lock first (a
//! lost supervisor is a lock anyone can take), writes its pid, reads the spec, gets the tree
//! onto the node and starts the container detached (`zigbox_image.zig` decides how), then waits
//! for it. Zigbox writes the run record; the agent reads that. If the container cannot be
//! started, the Zigbox diagnostic goes to `failed.json` and the process ends: no record exists.
//!
//! A SIGTERM to the supervisor goes to the container (Zigbox's `wait` forwards it), so an
//! operator who stops the supervisor does not leave an orphan.
//!
//! Needs a host that runs Zigbox; covered by `zigbox-smoke` only (docs/briefs/c2-1.md).

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const files = @import("fake_files.zig");
const image = @import("zigbox_image.zig");
const launch = @import("zigbox_launch.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Diagnostic = diag_mod.Diagnostic;

const HostReal = zigbox.host_real.HostReal;
const NetworkMemory = @typeInfo(@typeInfo(@FieldType(HostReal, "network_memory")).optional.child)
    .pointer.child;
const ImageWorkspace = @typeInfo(@typeInfo(@FieldType(zigbox.StartOptions, "image_workspace"))
    .optional.child).pointer.child;
const Facts = @FieldType(zigbox.Handle, "facts");

/// Everything one container's start needs that is too large for a stack: about 60 MiB, made on
/// the heap once. `handle` is pinned: Zigbox keeps pointers into the spec and into itself.
const Storage = struct {
    handle: zigbox.Handle,
    image_workspace: ImageWorkspace,
    pull_workspace: zigbox.pull.Workspace,
    import_workspace: zigbox.store.import.Workspace,
    pull_facts: Facts,
    pull_result: zigbox.pull.Result,
    network_memory: NetworkMemory,
};

/// How much of `ZBX_REGISTRY_MIRRORS` is read: more than Zigbox's 1024 (not exported), so that a
/// list that is too long reaches `pull` and is refused there, by Zigbox, not quietly ignored.
const mirrors_bytes_max: u32 = 4096;

/// The start and pull steps over real Zigbox, for `zigbox_image.start_with_image`.
const Real = struct {
    host: zigbox.host.Host,
    storage: *Storage,
    spec: *const zigbox.Spec,
    /// "b3:" and 64 hex digits (Zigbox's store_digest_text_bytes, not exported).
    tree_text: [67]u8 = undefined,

    fn steps(self: *Real) image.Steps {
        return .{ .context = self, .start = start, .pull = pull };
    }

    fn start(context: *anyopaque, diag: *zigbox.diag.Diag) error{StartFailed}!void {
        const self: *Real = @ptrCast(@alignCast(context));
        const options: zigbox.StartOptions = .{
            .detached = true,
            .image_workspace = &self.storage.image_workspace,
        };
        zigbox.start(self.host, self.spec, options, &self.storage.handle, diag) catch
            return error.StartFailed;
    }

    fn pull(
        context: *anyopaque,
        reference: []const u8,
        diag: *zigbox.diag.Diag,
    ) error{Failed}![]const u8 {
        const self: *Real = @ptrCast(@alignCast(context));
        const storage = self.storage;
        const request: zigbox.pull.Request = .{
            .reference = reference,
            .platform = .{},
            // Docker Hub mirrors, from the environment the agent gave this process.
            .mirrors = self.host.environment(
                "ZBX_REGISTRY_MIRRORS",
                mirrors_bytes_max,
            ) orelse "",
        };
        try zigbox.pull.pull(
            self.host,
            &storage.pull_facts,
            &request,
            null,
            &storage.pull_workspace,
            &storage.import_workspace,
            &storage.pull_result,
            diag,
        );
        const text = storage.pull_result.tree.text();
        @memcpy(self.tree_text[0..text.len], &text);
        return self.tree_text[0..text.len];
    }
};

pub fn run(init: std.process.Init, dir_path: []const u8) u8 {
    assert(dir_path.len > 0);
    // Not `init.io`: that is a threaded Io. Zigbox's start and pull make namespaces, which
    // needs a process with one thread, and this Io never starts another.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const dir = Dir.openDirAbsolute(io, dir_path, .{}) catch return constants.exit_environment;
    defer dir.close(io);
    // A new session and process group: signals aimed at the agent do not reach it.
    _ = std.os.linux.setsid();
    launch.hold_lock(io, dir) catch return constants.exit_environment;
    const own_pid: i32 = @intCast(std.os.linux.getpid());
    files.write_pid(io, dir, launch.file_supervisor, own_pid) catch
        return constants.exit_environment;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const spec = launch.read_spec(io, dir, arena_state.allocator()) catch
        return constants.exit_environment;
    const storage = std.heap.page_allocator.create(Storage) catch return constants.exit_environment;
    storage.network_memory.init();
    var real: HostReal = .{
        .environ = init.minimal.environ,
        .network_memory = &storage.network_memory,
    };
    return supervise(io, dir, real.interface(), storage, &spec, arena_state.allocator());
}

fn supervise(
    io: std.Io,
    dir: Dir,
    host: zigbox.host.Host,
    storage: *Storage,
    spec: *const launch.Spec,
    arena: Allocator,
) u8 {
    const container = container_spec(arena, spec) orelse return constants.exit_environment;
    var status: [4096]u8 = undefined;
    const count = if (host.read_file("/proc/self/status", &status)) |text|
        image.threads_in(text)
    else |_|
        null;
    if (count != 1) return record_failure(io, dir, &image.not_single_threaded(count));
    var real: Real = .{ .host = host, .storage = storage, .spec = &container };
    var trace: image.Trace = .{};
    switch (image.start_with_image(real.steps(), spec.tree, spec.reference, &trace)) {
        .started => {},
        .failed => |diagnostic| return record_failure(io, dir, &diagnostic),
    }
    _ = zigbox.wait(&storage.handle);
    return constants.exit_ok;
}

/// Writes `failed.json`, the last thing a supervisor that did not start a container does.
fn record_failure(io: std.Io, dir: Dir, diagnostic: *const Diagnostic) u8 {
    launch.write_failed(io, dir, diagnostic) catch return constants.exit_environment;
    return constants.exit_ok;
}

/// Zigbox's spec for the launch: the tree, the command, the environment and labels, the limits.
/// Everything borrows from `spec` and `arena`. Null if memory ran out.
fn container_spec(arena: Allocator, spec: *const launch.Spec) ?zigbox.Spec {
    const env = arena.alloc(zigbox.Label, spec.env.len) catch return null;
    const names = arena.alloc([]const u8, spec.env.len) catch return null;
    for (spec.env, env, names) |pair, *label, *name| {
        label.* = .{ .key = pair[0], .value = pair[1] };
        name.* = pair[0];
    }
    const labels = arena.alloc(zigbox.Label, spec.labels.len) catch return null;
    for (spec.labels, labels) |pair, *label| label.* = .{ .key = pair[0], .value = pair[1] };
    return .{
        .image = spec.tree,
        .name = spec.name,
        .command = spec.command,
        .labels = labels,
        .env = env,
        .env_names = names,
        .limits = .{
            .memory_bytes = spec.memory_bytes,
            .pids = spec.pids,
            .cpu_millis = spec.cpu_millis,
        },
    };
}
