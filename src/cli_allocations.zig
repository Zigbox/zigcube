//! `zcube check allocations` and `zcube repair allocations <node> [--confirm]` (docs/cli.md):
//! the allocation accounting as `GET /v1/check/allocations` reconstructs it, and the scheduler's
//! repair of one node, which `POST /v1/repair/allocations/{node}` runs in the request.
//!
//! The check prints its table and, when a node disagrees, fails with `ZC-E0404` (exit 1) so a
//! script notices. A repair without `--confirm` is sent without `confirm=true`: the server
//! refuses it with `ZC-E0401`, whose cause says what it would write.

const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli_args.zig");
const cli_commands = @import("cli_commands.zig");
const cli_data = @import("cli_data.zig");
const cli_env = @import("cli_env.zig");
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const cli_view = @import("cli_view.zig");

const Allocator = std.mem.Allocator;
const Client = cli_http.Client;
const Env = cli_env.Env;
const Error = cli_report.Error;
const Options = cli_args.Options;
const Report = cli_report.Report;
const Writer = std.Io.Writer;

const Tally = struct { cpu_millis: u64, memory_bytes: u64, count: u32 };

const Finding = struct { decision: []const u8, revision: u64 };

const CheckNode = struct {
    node: []const u8,
    recorded: ?Tally,
    reconstructed: Tally,
    consistent: bool,
    finding: ?Finding,
};

const Check = struct { revision: u64, nodes: []const CheckNode, inconsistent: u32 };

const Repaired = struct {
    request_id: []const u8,
    node: []const u8,
    recorded: Tally,
    reconstructed: Tally,
    revision: u64,
    decision: []const u8,
};

const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

pub fn check(env: *const Env, client: *Client, options: Options, report: *Report) Error!void {
    const arena = env.arena;
    const reply = try client.get("/v1/check/allocations", report);
    const body = std.json.parseFromSliceLeaky(Check, arena, reply.body, parse_options) catch
        return cli_data.contract(report, reply.request_id, "is not an allocation check");
    report.revision = body.revision;
    const out = if (options.output == .json)
        try std.fmt.allocPrint(arena, "{s}\n", .{std.mem.trimEnd(u8, reply.body, "\n")})
    else
        try check_text(arena, &body);
    try cli_commands.emit(env, .stdout, out, report);
    if (body.inconsistent == 0) return;
    for (body.nodes) |*node| {
        if (!node.consistent) return inconsistent(report, &body, node);
    }
    return cli_data.contract(report, reply.request_id, "counts a node it does not list");
}

/// One row per node: both totals, whether they agree, and the auditor's finding.
fn check_text(arena: Allocator, body: *const Check) Error![]const u8 {
    if (body.nodes.len == 0) return "no nodes hold or record an allocation\n";
    var out: Writer.Allocating = .init(arena);
    var cells: std.ArrayList([]const []const u8) = .empty;
    for (body.nodes) |*node| {
        const recorded = if (node.recorded) |tally| try tally_text(arena, tally) else "none";
        const finding = if (node.finding) |found| found.decision else "-";
        const line = try arena.dupe([]const u8, &.{
            node.node,
            recorded,
            try tally_text(arena, node.reconstructed),
            if (node.consistent) "yes" else "NO",
            finding,
        });
        try cells.append(arena, line);
    }
    const header: []const []const u8 = &.{ "NODE", "RECORDED", "ASSIGNED", "AGREE", "FINDING" };
    cli_view.write_table(&out.writer, header, cells.items) catch return error.OutOfMemory;
    const legend = "(assignments, cpu, memory)";
    out.writer.print("at revision {d}: {d} of {d} nodes disagree {s}\n", .{
        body.revision,
        body.inconsistent,
        body.nodes.len,
        legend,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// `3, 300m, 3072B`: assignments, cpu millis, memory bytes.
fn tally_text(arena: Allocator, tally: Tally) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d}, {d}m, {d}B", .{
        tally.count,
        tally.cpu_millis,
        tally.memory_bytes,
    });
}

fn inconsistent(report: *Report, body: *const Check, node: *const CheckNode) Error {
    assert(report.diag.code == null);
    assert(!node.consistent);
    const recorded = node.recorded orelse Tally{ .cpu_millis = 0, .memory_bytes = 0, .count = 0 };
    report.diag.raise(.E0404);
    report.diag.while_("checking the allocation accounting at revision {d}", .{body.revision});
    report.diag.cause(
        "{d} of {d} nodes disagree; the first, {s}, records {d} assignments and {d} cpu millis, " ++
            "its assignments sum to {d} and {d}",
        .{
            body.inconsistent,
            body.nodes.len,
            node.node,
            recorded.count,
            recorded.cpu_millis,
            node.reconstructed.count,
            node.reconstructed.cpu_millis,
        },
    );
    report.diag.fix_with("see what a repair would write:", "zcube repair allocations {s}", .{
        node.node,
    });
    return error.Failed;
}

pub fn repair(
    env: *const Env,
    client: *Client,
    options: Options,
    node: []const u8,
    report: *Report,
) Error!void {
    const arena = env.arena;
    report.subject = .{ .kind = .node, .name = node };
    const path = try std.fmt.allocPrint(arena, "/v1/repair/allocations/{s}{s}", .{
        try cli_data.percent_encode(arena, node),
        if (options.confirm) "?confirm=true" else "",
    });
    const reply = try client.send("POST", path, "", report);
    if (options.output == .json) return cli_commands.emit(
        env,
        .stdout,
        try std.fmt.allocPrint(arena, "{s}\n", .{std.mem.trimEnd(u8, reply.body, "\n")}),
        report,
    );
    const body = std.json.parseFromSliceLeaky(Repaired, arena, reply.body, parse_options) catch
        return cli_data.contract(report, reply.request_id, "is not a repair");
    report.revision = body.revision;
    const text = try std.fmt.allocPrint(
        arena,
        "repaired {s}: recorded {s}, now {s} (revision {d}, decision {s})\n",
        .{
            body.node,
            try tally_text(arena, body.recorded),
            try tally_text(arena, body.reconstructed),
            body.revision,
            body.decision,
        },
    );
    try cli_commands.emit(env, .stdout, text, report);
}

const testing = std.testing;

test "check: the table names both totals, the disagreement and the finding" {
    // Goal: the text of `zcube check allocations` is part of the product. Method: a fixed body
    // with one disagreeing node and one agreeing one, compared byte for byte.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const nodes = [_]CheckNode{
        .{
            .node = "node1",
            .recorded = .{ .cpu_millis = 300, .memory_bytes = 3072, .count = 3 },
            .reconstructed = .{ .cpu_millis = 200, .memory_bytes = 2048, .count = 2 },
            .consistent = false,
            .finding = .{ .decision = "0000000000042-0003-0001", .revision = 6 },
        },
        .{
            .node = "node2",
            .recorded = null,
            .reconstructed = .{ .cpu_millis = 0, .memory_bytes = 0, .count = 0 },
            .consistent = true,
            .finding = null,
        },
    };
    const body: Check = .{ .revision = 7, .nodes = &nodes, .inconsistent = 1 };
    const text = try check_text(arena_state.allocator(), &body);
    try testing.expectEqualStrings(
        \\NODE   RECORDED        ASSIGNED        AGREE  FINDING
        \\node1  3, 300m, 3072B  2, 200m, 2048B  NO     0000000000042-0003-0001
        \\node2  none            0, 0m, 0B       yes    -
        \\at revision 7: 1 of 2 nodes disagree (assignments, cpu, memory)
        \\
    , text);
    const empty: Check = .{ .revision = 7, .nodes = &.{}, .inconsistent = 0 };
    const none = try check_text(arena_state.allocator(), &empty);
    try testing.expectEqualStrings("no nodes hold or record an allocation\n", none);
}
