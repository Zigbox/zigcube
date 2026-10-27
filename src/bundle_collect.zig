//! What goes into a bundle and where it is read from. `zcube bundle --last` bundles the last
//! failure the command line recorded; `zcube bundle <kind> <name>` bundles a subject; a `bug`
//! diagnostic bundles itself. The evidence is the diagnostic, the command and request ids, and
//! from the server (best effort: a server that is down is the usual reason to want a bundle, so
//! each missing piece is a note in the bundle, not a failure) the `why` chain and the store keys
//! of the subject, at the failing revision when it is still there.

const std = @import("std");
const assert = std.debug.assert;
const bundle = @import("bundle.zig");
const cli_args = @import("cli_args.zig");
const cli_data = @import("cli_data.zig");
const cli_env = @import("cli_env.zig");
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Client = cli_http.Client;
const Env = cli_env.Env;
const Error = cli_report.Error;
const Report = cli_report.Report;
const Supplied = bundle.Supplied;

/// What the bundle is about, read from the failure record or from the arguments.
pub const Evidence = struct {
    command_line: []const u8,
    server: []const u8,
    request_id: []const u8,
    subject: ?cli_args.Subject,
    revision: ?u64,
    /// The diagnostics' JSON, one object per line.
    diagnostics: []const u8,
};

pub const Written = struct { saved: bundle.Saved, redacted: bool };

// ---- Commands ----------------------------------------------------------------------------------

/// `zcube bundle --last | <kind> <name>`. Returns the text for standard output.
pub fn run(
    env: *const Env,
    client: *Client,
    options: cli_args.Options,
    target: cli_args.BundleTarget,
    command_line: []const u8,
    report: *Report,
) Error![]const u8 {
    if (options.no_redact) warn_unredacted(env, options);
    var evidence: Evidence = switch (target) {
        .last => try last_failure(env, report),
        .subject => |subject| .{
            .command_line = command_line,
            .server = client.server_text,
            .request_id = "",
            .subject = subject,
            .revision = null,
            .diagnostics = "",
        },
    };
    if (target == .subject) evidence.subject = target.subject;
    const written = try write(env, client, evidence, !options.no_redact, report);
    return describe(env.arena, written, options.output);
}

/// The bundle of a bug, written by the boundary: puts the path in the `saved` of each bug
/// diagnostic of the report. A bundle that can't be written leaves the bug as it was: the bug is
/// the news, not the bundle.
pub fn automatic(
    env: *const Env,
    client: ?*Client,
    report: *Report,
    command_line: []const u8,
    server: []const u8,
) void {
    assert(report.diag.code == null); // Sealed.
    assert(report.has_bug());
    const arena = env.arena;
    const json = cli_report.failure_json(
        arena,
        report,
        command_line,
        server,
        env.now_ms(),
    ) catch return;
    const evidence: Evidence = .{
        .command_line = command_line,
        .server = server,
        .request_id = report.request_id.slice(),
        .subject = report.subject,
        .revision = report.revision,
        .diagnostics = diagnostics_lines(arena, json) catch return,
    };
    var scratch: Report = undefined;
    scratch.reset();
    const written = write(env, client, evidence, true, &scratch) catch return;
    for (report.diagnostics[0..report.count]) |*diagnostic| {
        if (diagnostic.severity != .bug) continue;
        diagnostic.saved = .{};
        diagnostic.saved.print("{s}", .{written.saved.slice()});
    }
}

fn warn_unredacted(env: *const Env, options: cli_args.Options) void {
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    bundle.unredacted_warning(&diag);
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const mode: cli_report.Mode = if (options.output == .json) .json else .text;
    const text = diag_mod.render(&diagnostic, mode, env.colour() and mode == .text, &buffer);
    env.stderr.writeAll(text) catch return; // A warning has nowhere else to go.
    env.stderr.flush() catch return;
}

// ---- Writing -----------------------------------------------------------------------------------

fn write(
    env: *const Env,
    client: ?*Client,
    evidence: Evidence,
    redacting: bool,
    report: *Report,
) Error!Written {
    const arena = env.arena;
    var files: std.ArrayList(Supplied) = .empty;
    try files.append(arena, .{
        .name = "command.txt",
        .why = "the command that failed (or was bundled), its server and its request id",
        .bytes = try std.fmt.allocPrint(arena, "{s}\nserver: {s}\nrequest id: {s}\n" ++
            "bundled at: {d} ms since the epoch\n", .{
            evidence.command_line,
            evidence.server,
            if (evidence.request_id.len == 0) "(none)" else evidence.request_id,
            env.now_ms(),
        }),
    });
    if (evidence.diagnostics.len > 0) {
        try files.append(arena, .{
            .name = "diagnostic.json",
            .why = "the diagnostics the command ended with, as `--output json` prints them",
            .bytes = evidence.diagnostics,
        });
    }
    if (client) |live| try gather(arena, live, evidence, &files);
    const label = try label_of(arena, evidence);
    var saved: bundle.Saved = undefined;
    saved.len = 0;
    saved.manifest = "";
    const request: bundle.Request = .{
        .env = env,
        .redact = redacting,
        .label = label,
        .files = files.items,
    };
    bundle.write(request, &saved, &report.diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BundleFailed => return error.Failed,
    };
    return .{ .saved = saved, .redacted = redacting };
}

fn label_of(arena: Allocator, evidence: Evidence) Allocator.Error![]const u8 {
    const subject = evidence.subject orelse return "last";
    return std.fmt.allocPrint(
        arena,
        "{s}-{s}",
        .{
            @tagName(subject.kind),
            subject.name[0..@min(subject.name.len, constants.service_name_bytes_max)],
        },
    );
}

fn describe(arena: Allocator, written: Written, output: cli_args.Output) Error![]const u8 {
    const path = written.saved.slice();
    if (output == .json) {
        const value = .{
            .path = path,
            .redacted = written.redacted,
            .manifest = written.saved.manifest,
        };
        const text = try std.json.Stringify.valueAlloc(arena, value, .{});
        return std.fmt.allocPrint(arena, "{s}\n", .{text});
    }
    return std.fmt.allocPrint(arena, "bundle saved: {s}\n" ++
        "it stays on this machine; review these files before you share it:\n\n{s}", .{
        path,
        written.saved.manifest,
    });
}

// ---- Evidence from the server ------------------------------------------------------------------

/// Reads the evidence from the server into files. Each piece that can't be had becomes a note.
const Gatherer = struct {
    arena: Allocator,
    client: *Client,
    files: *std.ArrayList(Supplied),
    /// The revision the failure was seen at, when it is known.
    revision: ?u64,

    /// One GET, as a file, or a note saying why there is none. True if the reply came.
    fn fetch(
        g: Gatherer,
        name: []const u8,
        why: []const u8,
        path: []const u8,
        records: bool,
    ) Error!bool {
        var scratch: Report = undefined;
        scratch.reset();
        const reply = g.client.get(path, &scratch) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed => {
                scratch.seal();
                try g.note(name, why, &scratch);
                return false;
            },
        };
        try g.files.append(g.arena, .{
            .name = name,
            .why = why,
            .bytes = reply.body,
            .records = records,
        });
        return true;
    }

    fn note(g: Gatherer, name: []const u8, why: []const u8, report: *const Report) Error!void {
        const extension = ".json";
        const has_extension = std.mem.endsWith(u8, name, extension);
        const stem = if (has_extension) name[0 .. name.len - extension.len] else name;
        try g.files.append(g.arena, .{
            .name = try std.fmt.allocPrint(g.arena, "{s}.unavailable.txt", .{stem}),
            .why = try std.fmt.allocPrint(g.arena, "{s}: not available", .{why}),
            .bytes = try unavailable(g.arena, report),
        });
    }

    /// The store keys under a prefix, at the failing revision when that is still there, else now.
    fn keys(g: Gatherer, name: []const u8, comptime format: []const u8, args: anytype) Error!void {
        const prefix = try std.fmt.allocPrint(g.arena, format, args);
        const encoded = try cli_data.percent_encode(g.arena, prefix);
        const now_path = try std.fmt.allocPrint(g.arena, "/v1/list?prefix={s}&limit={d}", .{
            encoded, constants.api_list_limit_max,
        });
        if (g.revision) |at| {
            const at_path = try std.fmt.allocPrint(g.arena, "{s}&at={d}", .{ now_path, at });
            const why = try std.fmt.allocPrint(g.arena, "store keys under {s} at revision {d}, " ++
                "where the failure was seen", .{ prefix, at });
            if (try g.fetch(name, why, at_path, true)) return;
        }
        const why = try std.fmt.allocPrint(g.arena, "store keys under {s} as they are now " ++
            "(the failing revision is not known or is gone)", .{prefix});
        _ = try g.fetch(name, why, now_path, true);
    }
};

/// Everything the server can say about the subject.
fn gather(
    arena: Allocator,
    client: *Client,
    evidence: Evidence,
    files: *std.ArrayList(Supplied),
) Error!void {
    const g: Gatherer = .{
        .arena = arena,
        .client = client,
        .files = files,
        .revision = evidence.revision,
    };
    _ = try g.fetch("status.json", "GET /v1/status: the server and its store", "/v1/status", false);
    const subject = evidence.subject orelse return g.keys("keys/services.json", "/services/", .{});
    const encoded = try cli_data.percent_encode(arena, subject.name);
    const kind = @tagName(subject.kind);
    const path = try std.fmt.allocPrint(arena, "/v1/why/{s}/{s}", .{ kind, encoded });
    const why = "GET /v1/why: the chain of decisions that explains the subject";
    _ = try g.fetch("why.json", why, path, false);
    const name = subject.name;
    switch (subject.kind) {
        .service => {
            try g.keys("keys/service.json", "/services/{s}", .{name});
            try g.keys("keys/replicas.json", "/replicas/{s}/", .{name});
        },
        .replica => {
            try g.keys("keys/replica.json", "/replicas/{s}/{s}", .{ service_of(name), name });
        },
        .node => try g.keys("keys/node.json", "/nodes/{s}", .{name}),
    }
    try g.keys("keys/decisions.json", "/decisions-by-subject/{s}/{s}/", .{ kind, name });
    try g.keys("keys/observed.json", "/observed/", .{});
}

/// `hello-3` is a replica of `hello`: the replica id is `<service>-<n>` (docs/keys.md).
fn service_of(replica: []const u8) []const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, replica, '-') orelse return replica;
    return replica[0..dash];
}

fn unavailable(arena: Allocator, report: *const Report) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    const intro = "unavailable at bundle time; the reason, as the command line shows it:\n\n";
    writer.writeAll(intro) catch return error.OutOfMemory;
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    for (report.shown()) |*diagnostic| {
        const text = diag_mod.render(diagnostic, .verbose, false, &buffer);
        writer.writeAll(text) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

// ---- The recorded failure ----------------------------------------------------------------------

/// Writes the record of a failure to the state directory, for `bundle --last`. Best effort: a
/// failure that can't be recorded is still reported, and `bundle --last` then says there is none.
pub fn record_failure(
    env: *const Env,
    report: *const Report,
    command_line: []const u8,
    server: []const u8,
) void {
    var state_buffer: [constants.state_path_bytes_max]u8 = undefined;
    const state = env.state_dir(&state_buffer) orelse return;
    const json = cli_report.failure_json(
        env.arena,
        report,
        command_line,
        server,
        env.now_ms(),
    ) catch return;
    if (json.len > constants.last_failure_bytes_max) return;
    var path_buffer: [constants.state_path_bytes_max + 64]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}",
        .{ state, constants.last_failure_file_name },
    ) catch return;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(env.io, state) catch return;
    cwd.writeFile(
        env.io,
        .{ .sub_path = path, .data = json, .flags = .{ .permissions = .fromMode(0o600) } },
    ) catch return;
}

fn last_failure(env: *const Env, report: *Report) Error!Evidence {
    var state_buffer: [constants.state_path_bytes_max]u8 = undefined;
    const state = env.state_dir(&state_buffer) orelse return no_failure(
        report,
        "there is no state directory to look in",
    );
    var path_buffer: [constants.state_path_bytes_max + 64]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}",
        .{ state, constants.last_failure_file_name },
    ) catch return no_failure(report, "the state directory's path is too long");
    const limit: std.Io.Limit = .limited(constants.last_failure_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(env.io, path, env.arena, limit) catch
        return no_failure(report, "no failure has been recorded, or the record can't be read");
    return read_failure(env.arena, text, report);
}

fn read_failure(arena: Allocator, text: []const u8, report: *Report) Error!Evidence {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
        return no_failure(report, "the record of the last failure is damaged");
    const command = cli_data.text(value, "command") orelse return no_failure(
        report,
        "the record of the last failure is damaged",
    );
    const list = cli_data.array(value, "diagnostics") orelse return no_failure(
        report,
        "the record of the last failure is damaged",
    );
    var lines: std.Io.Writer.Allocating = .init(arena);
    for (list) |item| {
        const line = try std.json.Stringify.valueAlloc(arena, item, .{});
        lines.writer.print("{s}\n", .{line}) catch return error.OutOfMemory;
    }
    var subject: ?cli_args.Subject = null;
    if (cli_data.text(value, "kind")) |kind_text| {
        const kind = std.meta.stringToEnum(cli_args.Kind, kind_text);
        const name = cli_data.text(value, "name");
        if (kind != null and name != null) subject = .{ .kind = kind.?, .name = name.? };
    }
    return .{
        .command_line = command,
        .server = cli_data.text(value, "server") orelse "",
        .request_id = cli_data.text(value, "request_id") orelse "",
        .subject = subject,
        .revision = cli_data.number(value, "revision"),
        .diagnostics = try lines.toOwnedSlice(),
    };
}

fn diagnostics_lines(arena: Allocator, failure: []const u8) Error![]const u8 {
    var none: Report = undefined;
    none.reset();
    const evidence = try read_failure(arena, failure, &none);
    return evidence.diagnostics;
}

fn no_failure(report: *Report, why: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0117);
    report.diag.while_("looking for the last failure", .{});
    report.diag.cause("{s}", .{why});
    report.diag.fix(
        .{ .sentence = "name what to bundle:", .command = "zcube bundle service <name>" },
    );
    return error.Failed;
}
