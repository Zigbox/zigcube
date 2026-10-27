//! Diagnostic bundles (DIAGNOSTICS.md, "Bundles: the kitchen sink, only when needed"): one
//! `.tar.gz` with what is needed to diagnose a failure without a back-and-forth. `zcube bundle`
//! writes one on request; a `bug` diagnostic writes one by itself. The pattern is Zigbox's
//! `bundle.zig`; what differs is the evidence (the diagnostic, the `why` chain and the store keys
//! at the failing revision, not a run record and `doctor`).
//!
//! Everything is bounded. The files are staged in one workspace (each cut at
//! `bundle_file_bytes_max`, and the manifest says so), redacted on the way in (`bundle_redact.zig`
//! and the environment values), then written through std's tar writer into std's gzip compressor,
//! which writes into a second fixed buffer. The bundle is saved under a temporary name and
//! renamed, so a full disk leaves no half file. It goes to the state directory and nowhere else:
//! a bundle never leaves the machine.
//!
//! Layout, in a directory named like the file without `.tar.gz`:
//!   MANIFEST.txt      every file and why it is there; what was cut; what was redacted
//!   version.txt       the zcube version and how it was built
//!   uname.txt, os-release.txt   kernel and distribution
//!   environment.txt   the names of the environment variables; their values are redacted
//!   then what the caller supplies: diagnostic.json, command.txt, status.json, why.json, keys/…
//!
//! The panic handler does not write a bundle, on purpose: it would need a workspace and std's
//! compressor, whose own assertions would be a second panic inside the handler. A `bug` the code
//! raises as a diagnostic does get one (`cli.zig`).

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const redact = @import("bundle_redact.zig");
const cli_env = @import("cli_env.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Env = cli_env.Env;
const flate = std.compress.flate;

pub const Error = error{ BundleFailed, OutOfMemory };

/// A file the caller wants in the bundle.
pub const Supplied = struct {
    name: []const u8,
    why: []const u8,
    bytes: []const u8,
    /// The source was already cut by the caller.
    cut: bool = false,
    /// JSON of store records: every `env` value is replaced, whatever its name, before the
    /// textual redactor looks at it.
    records: bool = false,
};

pub const Request = struct {
    env: *const Env,
    /// Replace secrets (the default). Off only for `--no-redact`.
    redact: bool,
    /// What the bundle is about, in its file name: `last`, `service-hello`.
    label: []const u8,
    files: []const Supplied,
};

/// Where a bundle went.
pub const Saved = struct {
    path: [constants.state_path_bytes_max + 128]u8,
    len: u32,
    /// The manifest, in the workspace (which lives as long as the process arena).
    manifest: []const u8,

    pub fn slice(saved: *const Saved) []const u8 {
        assert(saved.len > 0);
        return saved.path[0..saved.len];
    }
};

const File = struct {
    name: []const u8,
    why: []const u8,
    start: u32,
    len: u32,
    /// Cut at a bound: the source was longer than what is kept.
    cut: bool,
    redactions: u32,
};

/// All the memory a bundle needs, allocated once from the process arena.
const Workspace = struct {
    stage: [constants.bundle_stage_bytes_max]u8,
    used: u32,
    raw: [constants.bundle_file_bytes_max]u8,
    files: [constants.bundle_files_max]File,
    count: u32,
    manifest_len: u32,
    secrets: [constants.bundle_secrets_max][]const u8,
    secrets_count: u32,
    redact: bool,
    redactions: u32,
    gz: [constants.bundle_gz_bytes_max]u8,
    window: [flate.max_window_len]u8,
    mask: redact.Mask,

    fn reset(ws: *Workspace, redacting: bool) void {
        ws.used = constants.bundle_manifest_bytes_max;
        ws.count = 0;
        ws.manifest_len = 0;
        ws.secrets_count = 0;
        ws.redact = redacting;
        ws.redactions = 0;
        assert(ws.used < ws.stage.len);
    }

    /// Stages `source` as a file of the bundle: redacted unless redaction is off, and cut at the
    /// bounds. A full workspace drops the file and the manifest says so.
    fn add(
        ws: *Workspace,
        name: []const u8,
        why: []const u8,
        source: []const u8,
        cut: bool,
        records: bool,
    ) void {
        assert(name.len > 0);
        if (ws.count == constants.bundle_files_max - 1) return; // One slot is the manifest's.
        const room = @min(constants.bundle_file_bytes_max, ws.stage.len - ws.used);
        const target = ws.stage[ws.used..][0..room];
        var length: u32 = 0;
        var was_cut = cut;
        var redactions: u32 = 0;
        if (room == 0) {
            was_cut = true;
        } else if (ws.redact) {
            const secrets = ws.secrets[0..ws.secrets_count];
            ws.mask.records = records;
            const result = redact.redact_with(
                &ws.mask,
                source[0..@min(source.len, constants.bundle_file_bytes_max)],
                target,
                secrets,
            );
            length = result.len;
            redactions = result.redactions;
            was_cut = was_cut or result.truncated or source.len > constants.bundle_file_bytes_max;
        } else {
            length = @intCast(@min(source.len, room));
            @memcpy(target[0..length], source[0..length]);
            was_cut = was_cut or length < source.len;
        }
        ws.push(name, why, length, was_cut, redactions);
    }

    /// Stages text that is safe as it is (text this file built itself).
    fn add_trusted(
        ws: *Workspace,
        name: []const u8,
        why: []const u8,
        source: []const u8,
        cut: bool,
    ) void {
        if (ws.count == constants.bundle_files_max - 1) return;
        const room = @min(constants.bundle_file_bytes_max, ws.stage.len - ws.used);
        const length: u32 = @intCast(@min(source.len, room));
        @memcpy(ws.stage[ws.used..][0..length], source[0..length]);
        ws.push(name, why, length, cut or length < source.len, 0);
    }

    fn push(
        ws: *Workspace,
        name: []const u8,
        why: []const u8,
        length: u32,
        cut: bool,
        n: u32,
    ) void {
        assert(ws.used + length <= ws.stage.len);
        ws.files[ws.count] = .{
            .name = name,
            .why = why,
            .start = ws.used,
            .len = length,
            .cut = cut,
            .redactions = n,
        };
        ws.count += 1;
        ws.used += length;
        ws.redactions += n;
    }

    fn content(ws: *const Workspace, file: *const File) []const u8 {
        assert(
            file.start >= constants.bundle_manifest_bytes_max,
        ); // The manifest's room comes first.
        assert(file.start + file.len <= ws.used);
        return ws.stage[file.start..][0..file.len];
    }
};

// ---- The UTC timestamp -------------------------------------------------------------------------

/// "2026-10-23T22-41-07Z": the form DIAGNOSTICS.md shows, with '-' for ':' so it is a file name.
pub fn timestamp(seconds: u64, buffer: *[constants.timestamp_bytes]u8) []const u8 {
    const since: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = since.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_time = since.getDaySeconds();
    const format = "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}Z";
    const text = std.fmt.bufPrint(buffer, format, .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_time.getHoursIntoDay(),
        day_time.getMinutesIntoHour(),
        day_time.getSecondsIntoMinute(),
    }) catch unreachable; // The text is 20 bytes for every year below 10000.
    assert(text.len == constants.timestamp_bytes);
    return text;
}

// ---- The sources -------------------------------------------------------------------------------

fn stage_system_files(ws: *Workspace, env: *const Env) void {
    var writer = std.Io.Writer.fixed(&ws.raw);
    // Cannot fail: a few short lines into a buffer of 128 KiB.
    writer.print("zcube {s}\nbuild: {s} {s}-{s}\n", .{
        env.version, @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag),
    }) catch unreachable; // A few short lines into a buffer of 128 KiB.
    ws.add_trusted(
        "version.txt",
        "the zcube version and how it was built",
        writer.buffered(),
        false,
    );
    stage_uname(ws);
    stage_os_release(ws, env);
}

/// The kernel release and machine. The host name is left out: it names the machine, and nothing in
/// a diagnosis needs it.
fn stage_uname(ws: *Workspace) void {
    const name = std.posix.uname();
    const release = std.mem.sliceTo(&name.release, 0);
    const machine = std.mem.sliceTo(&name.machine, 0);
    var writer = std.Io.Writer.fixed(&ws.raw);
    // Cannot fail: two short fields into a buffer of 128 KiB.
    writer.print("release: {s}\nmachine: {s}\n", .{ release, machine }) catch unreachable;
    ws.add_trusted(
        "uname.txt",
        "the kernel release and machine (not the host name)",
        writer.buffered(),
        false,
    );
}

fn stage_os_release(ws: *Workspace, env: *const Env) void {
    const limit: std.Io.Limit = .limited(constants.bundle_file_bytes_max);
    const cwd = std.Io.Dir.cwd();
    const found = cwd.readFileAlloc(env.io, "/etc/os-release", env.arena, limit) catch {
        ws.add_trusted(
            "os-release.txt",
            "the distribution",
            "unavailable: /etc/os-release could not be read\n",
            false,
        );
        return;
    };
    ws.add("os-release.txt", "the distribution", found, false, false);
}

/// The names of the environment variables. The values are never copied with redaction on: each
/// shows as `[redacted:env]`; only `--no-redact` keeps them.
fn stage_environment(ws: *Workspace, env: *const Env) void {
    var writer = std.Io.Writer.fixed(&ws.raw);
    var iterator = env.environ.iterator();
    var cut = false;
    var seen: u32 = 0;
    while (iterator.next()) |entry| : (seen += 1) {
        if (seen == constants.environment_entries_max) {
            cut = true;
            break;
        }
        const value = if (ws.redact) "[redacted:env]" else entry.value_ptr.*;
        writer.print("{s}={s}\n", .{ entry.key_ptr.*, value }) catch {
            cut = true;
            break;
        };
    }
    const why = "the environment variables of zcube; values are redacted unless --no-redact";
    if (ws.redact) {
        ws.add_trusted("environment.txt", why, writer.buffered(), cut);
    } else {
        ws.add("environment.txt", why, writer.buffered(), cut, false);
    }
}

/// Secret-named variables whose values are scrubbed wherever they appear in the bundle.
fn collect_secrets(ws: *Workspace, env: *const Env) void {
    assert(ws.redact); // Without redaction nothing is scrubbed, so nothing is collected.
    assert(ws.secrets_count == 0);
    var iterator = env.environ.iterator();
    while (iterator.next()) |entry| {
        if (redact.secret_kind(entry.key_ptr.*) == null) continue;
        const value = entry.value_ptr.*;
        if (value.len < constants.secret_value_bytes_min) continue;
        if (value.len > constants.secret_value_bytes_max) continue;
        if (ws.secrets_count == constants.bundle_secrets_max) break;
        ws.secrets[ws.secrets_count] = value;
        ws.secrets_count += 1;
    }
}

fn stage_supplied(ws: *Workspace, arena: Allocator, files: []const Supplied) Allocator.Error!void {
    for (files) |file| {
        if (ws.redact and file.records) {
            const structured = redact.redact_env_values(
                arena,
                file.bytes,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Not JSON (a cut file): the textual net below is all there is.
                error.NotJson => file.bytes,
            };
            ws.add(file.name, file.why, structured, file.cut, true);
        } else {
            ws.add(file.name, file.why, file.bytes, file.cut, false);
        }
    }
}

// ---- The manifest ------------------------------------------------------------------------------

fn write_manifest(ws: *Workspace, env: *const Env, stem: []const u8, label: []const u8) void {
    const out = ws.stage[0..constants.bundle_manifest_bytes_max];
    var writer = std.Io.Writer.fixed(out);
    // Cannot fail: the comptime check below proves the manifest fits its room.
    write_manifest_text(&writer, ws, env, stem, label) catch unreachable;
    const text = writer.buffered();
    assert(text.len > 0);
    ws.manifest_len = @intCast(text.len);
}

fn write_manifest_text(
    writer: *std.Io.Writer,
    ws: *const Workspace,
    env: *const Env,
    stem: []const u8,
    label: []const u8,
) std.Io.Writer.Error!void {
    assert(stem.len > label.len);
    try writer.print("zcube diagnostic bundle {s}\n", .{stem});
    try writer.print("zcube {s}, about \"{s}\"\n\n", .{ env.version, label });
    if (ws.redact) {
        try writer.print(
            "redaction: on (values replaced: {d}, shown as [redacted:<kind>])\n",
            .{ws.redactions},
        );
        try writer.writeAll("  a net, not a proof: a secret with an innocent name can pass\n");
    } else {
        try writer.writeAll(
            "redaction: OFF (--no-redact): secrets are in this bundle as they were\n",
        );
    }
    try writer.writeAll(
        "review every file before you share this bundle; zcube never uploads it\n\n",
    );
    try writer.writeAll("files:\n");
    try writer.writeAll("  MANIFEST.txt\n    this list\n");
    for (ws.files[0..ws.count]) |*file| {
        try writer.print("  {s} ({d} bytes)\n    {s}\n", .{ file.name, file.len, file.why });
        if (file.cut) try writer.writeAll(
            "    cut at a bound: the source was longer than what is kept\n",
        );
        if (file.redactions > 0) try writer.print("    values redacted: {d}\n", .{file.redactions});
    }
}

comptime {
    // A header of a few hundred bytes and, per file, a line of at most 160 and two notes of 80.
    const per_file = 160 + 80 + 80;
    assert(1024 + constants.bundle_files_max * per_file < constants.bundle_manifest_bytes_max);
}

// ---- Compression -------------------------------------------------------------------------------

const CompressError = error{TooBig};

/// The bundle as a gzip'd tar, in `ws.gz`. Every file is under a directory named `stem`.
fn compress(ws: *Workspace, stem: []const u8, now_seconds: u64) CompressError![]const u8 {
    var out = std.Io.Writer.fixed(&ws.gz);
    var gzip = flate.Compress.Huffman.init(&out, &ws.window, .gzip) catch return error.TooBig;
    var archive: std.tar.Writer = .{ .underlying_writer = &gzip.writer };
    const options: std.tar.Writer.Options = .{ .mode = 0o600, .mtime = now_seconds };
    archive.setRoot(stem) catch return error.TooBig;
    const manifest = ws.stage[0..ws.manifest_len];
    archive.writeFileBytes("MANIFEST.txt", manifest, options) catch return error.TooBig;
    for (ws.files[0..ws.count]) |*file| {
        archive.writeFileBytes(file.name, ws.content(file), options) catch return error.TooBig;
    }
    archive.finishPedantically() catch return error.TooBig;
    gzip.finish() catch return error.TooBig;
    const bytes = out.buffered();
    assert(bytes.len > 18); // A gzip header and footer.
    return bytes;
}

// ---- Saving ------------------------------------------------------------------------------------

fn save(
    env: *const Env,
    stem: []const u8,
    bytes: []const u8,
    saved: *Saved,
    diag: *Diag,
) Error!void {
    var state_buffer: [constants.state_path_bytes_max]u8 = undefined;
    const state = env.state_dir(&state_buffer) orelse return no_state(diag);
    var dir_storage: [constants.state_path_bytes_max + 16]u8 = undefined;
    const dir = std.fmt.bufPrint(
        &dir_storage,
        "{s}/{s}",
        .{ state, constants.bundles_dir_name },
    ) catch return path_too_long(diag, state);
    var final_storage: [constants.state_path_bytes_max + 128]u8 = undefined;
    var temporary_storage: [constants.state_path_bytes_max + 128]u8 = undefined;
    const final = std.fmt.bufPrint(
        &final_storage,
        "{s}/{s}.tar.gz",
        .{ dir, stem },
    ) catch return path_too_long(diag, dir);
    const temporary = std.fmt.bufPrint(
        &temporary_storage,
        "{s}/.{s}.tar.gz.tmp",
        .{ dir, stem },
    ) catch return path_too_long(diag, dir);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(env.io, dir) catch |err| return write_failed(diag, dir, reason(err));
    cwd.writeFile(
        env.io,
        .{ .sub_path = temporary, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } },
    ) catch |err| {
        cwd.deleteFile(env.io, temporary) catch {}; // A partial file must not stay.
        return write_failed(diag, final, reason(err));
    };
    cwd.rename(temporary, cwd, final, env.io) catch |err| {
        cwd.deleteFile(env.io, temporary) catch {}; // Same.
        return write_failed(diag, final, reason(err));
    };
    @memcpy(saved.path[0..final.len], final);
    saved.len = @intCast(final.len);
}

fn reason(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.NoSpaceLeft => "no space left on the device",
        error.ReadOnlyFileSystem => "the file system is read-only",
        error.NotDir => "a part of the path is not a directory",
        error.FileNotFound => "a directory of the path is missing",
        error.DiskQuota => "the disk quota is used up",
        else => "the system refused the write",
    };
}

fn no_state(diag: *Diag) Error {
    assert(diag.code == null);
    diag.raise(.E0116);
    diag.while_("looking for the state directory", .{});
    diag.cause("neither XDG_STATE_HOME nor HOME names an absolute directory", .{});
    diag.fix(.{ .sentence = "name one:", .command = "export XDG_STATE_HOME=$HOME/.local/state" });
    return error.BundleFailed;
}

fn path_too_long(diag: *Diag, directory: []const u8) Error {
    assert(diag.code == null);
    diag.raise(.E0116);
    diag.while_("choosing the bundle's file name", .{});
    diag.cause("the path under {s} is too long", .{directory});
    diag.fix(
        .{
            .sentence = "use a shorter state directory:",
            .command = "export XDG_STATE_HOME=$HOME/.zstate",
        },
    );
    return error.BundleFailed;
}

fn write_failed(diag: *Diag, path: []const u8, why: []const u8) Error {
    assert(diag.code == null);
    diag.raise(.E0116);
    diag.while_("saving the bundle", .{});
    diag.cause("{s}: {s}", .{ path, why });
    diag.context("path", "{s}", .{path});
    diag.fix(
        .{
            .sentence = "use a state directory you can write, with room:",
            .command = "export XDG_STATE_HOME=/path/with/room",
        },
    );
    return error.BundleFailed;
}

fn too_big(diag: *Diag) Error {
    assert(diag.code == null);
    diag.raise(.B0002);
    diag.while_("compressing the bundle", .{});
    diag.cause("the bundle does not fit in {d} bytes", .{constants.bundle_gz_bytes_max});
    return error.BundleFailed;
}

/// `--no-redact` was given: a warning, not a failure.
pub fn unredacted_warning(diag: *Diag) void {
    assert(diag.code == null);
    diag.raise(.W0119);
    diag.while_("choosing what to keep in the bundle", .{});
    diag.cause("--no-redact keeps environment values and secrets in the bundle", .{});
    diag.fix(
        .{ .sentence = "read every file in it before you share it, or leave --no-redact out" },
    );
    assert(diag.entry().severity == .warning);
}

// ---- The entry point ---------------------------------------------------------------------------

/// Writes a bundle for `request` and says where it went. The reason for a failure is in `diag`.
pub fn write(request: Request, saved: *Saved, diag: *Diag) Error!void {
    assert(diag.code == null);
    assert(request.label.len > 0);
    assert(request.label.len <= constants.service_name_bytes_max + 9);
    const env = request.env;
    const ws = try env.arena.create(Workspace);
    ws.reset(request.redact);
    if (ws.redact) collect_secrets(ws, env);
    stage_system_files(ws, env);
    stage_environment(ws, env);
    try stage_supplied(ws, env.arena, request.files);
    const now = env.now_ms();
    var stamp: [constants.timestamp_bytes]u8 = undefined;
    var stem_storage: [constants.bundle_name_bytes_max]u8 = undefined;
    const stem = std.fmt.bufPrint(
        &stem_storage,
        "{s}-{s}",
        .{ timestamp(@divFloor(now, 1000), &stamp), request.label },
    ) catch unreachable; // A timestamp and a label of at most 57 bytes.
    write_manifest(ws, env, stem, request.label);
    const bytes = compress(ws, stem, @divFloor(now, 1000)) catch return too_big(diag);
    try save(env, stem, bytes, saved, diag);
    saved.manifest = ws.stage[0..ws.manifest_len];
}

const testing = std.testing;

test "the timestamp is the form DIAGNOSTICS.md shows" {
    // Goal: the file name of a bundle. Method: the dates the standard and a leap day use.
    var buffer: [constants.timestamp_bytes]u8 = undefined;
    try testing.expectEqualStrings("2026-10-23T22-41-07Z", timestamp(1792795267, &buffer));
    try testing.expectEqualStrings("1970-01-01T00-00-00Z", timestamp(0, &buffer));
    try testing.expectEqualStrings("2024-02-29T12-00-00Z", timestamp(1709208000, &buffer));
}
