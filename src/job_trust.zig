//! The server's signature check at admission (B5, docs/briefs/b5.md): `POST /v1/jobs` asks
//! Zigbox's `verdict.judge` whether the job's `signatures` satisfy the trust policy of the
//! server's configuration, for the job's image, before anything is written. Core code: the
//! policy is parsed by the shell at start, and the scratch the verdict needs (several MiB) is
//! allocated once by whoever builds the `Api`.
//!
//! **The subject** is M8's, unchanged: the tree is the job's `image` (`b3:<hex>`), and a job with
//! a `source` binds the manifest digest that ends it. A tree-only signature counts for any job of
//! that tree; a signature bound to a manifest counts only for a job pulled from that manifest.
//!
//! **The refusal** is Zigbox's ZBX-E0905 (or ZBX-E0906 for a provenance rule), written as
//! Zigbox's run gate writes it (`trust/diagnose.zig`, `unsigned`; that file imports the host, so
//! it is not part of `zigbox.trust` and the text is mirrored here). The caller answers 403 with
//! it, and no job is created.
//!
//! **The shape** of the field is checked whether or not a policy is set (`shape_problem`, ZC-E0130
//! naming the bound); whether a line is an envelope at all is checked only under a policy, when
//! the verdict reads it.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const constants = @import("constants.zig");

const trust = zigbox.trust;
pub const Diagnostic = zigbox.diagnostic.Diagnostic;
const Statement = trust.statement.Statement;

comptime {
    // The brief's bounds are a subset of what Zigbox reads: a job's lines always fit a record,
    // and `Record.add`'s asserts hold for every line `shape_problem` passes.
    assert(constants.job_signatures_max <= trust.limits.signatures_per_tree_max);
    assert(constants.job_signature_bytes_max <= trust.limits.envelope_bytes_max);
}

/// What one verdict uses. About 3.7 MiB: allocate it, never put it on the stack. One per `Api`:
/// the shell runs the writes one at a time.
pub const Scratch = struct {
    work: trust.dsse.Work,
    record: trust.signature_record.Record,
    report: trust.verdict.Report,
};

/// The server's trust configuration, as `server_config.zig` read it at start.
pub const Trust = struct {
    policy: *const trust.policy.Policy,
    /// The policy file's path, as the configuration names it: the refusal names it.
    path: []const u8,
    scratch: *Scratch,
};

/// Faults the teeth tests switch on to show that a test fails without each check. Never on
/// outside a test build.
pub const TestFault = enum {
    /// No verdict: every job is admitted.
    skip_admission,
    /// Any line counts, whatever the verdict said of it.
    count_any_line,
    /// The subject is read from the first line's own statement, not from the job.
    subject_from_signature,
    /// `shape_problem` passes everything.
    skip_bounds,
    /// The node's check before a run starts (`judge_run`) starts every run.
    skip_node_check,
};

var faults: [std.enums.values(TestFault).len]bool = @splat(false);

pub fn set_test_fault(fault: TestFault, on: bool) void {
    if (builtin.is_test) faults[@backingInt(fault)] = on;
}

fn fault_on(fault: TestFault) bool {
    return builtin.is_test and faults[@backingInt(fault)];
}

/// What is wrong with the shape of a job's `signatures`, or null. The caller refuses it as
/// ZC-E0130 under the field's name.
pub fn shape_problem(buffer: []u8, signatures: []const []const u8) ?[]const u8 {
    if (fault_on(.skip_bounds)) return null;
    if (signatures.len > constants.job_signatures_max) {
        return std.fmt.bufPrint(buffer, "at most {d} envelopes, there are {d}", .{
            constants.job_signatures_max, signatures.len,
        }) catch unreachable; // The buffer holds the sentence and two numbers.
    }
    for (signatures, 1..) |line, number| {
        if (line.len == 0 or line.len > constants.job_signature_bytes_max) {
            return std.fmt.bufPrint(buffer, "envelope {d} must be 1 to {d} bytes, it is {d}", .{
                number, constants.job_signature_bytes_max, line.len,
            }) catch unreachable; // The buffer holds the sentence and three numbers.
        }
        for (line) |byte| {
            if (byte < ' ' or byte > '~') {
                return std.fmt.bufPrint(
                    buffer,
                    "envelope {d} must be one line of printable ASCII, as zbx trust export " ++
                        "writes it",
                    .{number},
                ) catch unreachable; // The buffer holds the sentence and a number.
            }
        }
    }
    return null;
}

/// The bytes `shape_problem` needs for its sentence.
pub const problem_bytes_max = 128;

/// What `admit` decided.
pub const Admission = union(enum) {
    admitted,
    /// Envelope `number` (from 1) is not a DSSE envelope Zigbox reads: ZC-E0130, the caller's.
    malformed: u32,
    /// No trusted line covers the job: ZBX-E0905 (or E0906), in the caller's arena.
    refused: *const Diagnostic,
};

pub const Job = struct {
    image: []const u8,
    source: []const u8,
    signatures: []const []const u8,
};

/// Judges `job` under `config`. A policy that asks for nothing admits every job without reading
/// the lines. The lines' shape was checked (`shape_problem`).
pub fn admit(
    config: *const Trust,
    arena: std.mem.Allocator,
    job: Job,
) error{OutOfMemory}!Admission {
    assert(job.signatures.len <= constants.job_signatures_max);
    if (fault_on(.skip_admission)) return .admitted;
    if (!config.policy.checks()) return .admitted;
    const scratch = config.scratch;
    scratch.record.clear();
    for (job.signatures, 1..) |line, number| {
        _ = trust.dsse.parse(&scratch.work, line) catch return .{ .malformed = @intCast(number) };
        // At most `job_signatures_max` lines, under Zigbox's count (the comptime block above).
        _ = scratch.record.add(line) catch unreachable;
    }
    const refused = try judge_lines(config, arena, job) orelse return .admitted;
    return .{ .refused = refused };
}

/// The node's check before a run starts (B5 slice 2, the agent): `job` under the node's own
/// policy. Null when the run may start; otherwise ZBX-E0905 (or E0906), in `arena`. Unlike
/// `admit`, a line that is not an envelope is not an error of the request: it is judged as
/// Zigbox's run gate judges it, a line that does not count. A run's lines passed the server's
/// shape check, but a row written around the API is held to the same bounds here: over the
/// bounds, nothing counts.
pub fn judge_run(
    config: *const Trust,
    arena: std.mem.Allocator,
    job: Job,
) error{OutOfMemory}!?*const Diagnostic {
    if (!config.policy.checks()) return null;
    if (fault_on(.skip_node_check)) return null;
    config.scratch.record.clear();
    var problem: [problem_bytes_max]u8 = undefined;
    if (shape_problem(&problem, job.signatures) == null) {
        for (job.signatures) |line| {
            // A line the record holds already is a duplicate, and counts once.
            _ = config.scratch.record.add(line) catch unreachable; // Bounded by the shape.
        }
    }
    return judge_lines(config, arena, job);
}

/// The verdict on the lines in `config.scratch.record`: null when they satisfy the policy,
/// else the refusal.
fn judge_lines(
    config: *const Trust,
    arena: std.mem.Allocator,
    job: Job,
) error{OutOfMemory}!?*const Diagnostic {
    const scratch = config.scratch;
    const tree = tree_of(job.image) orelse return try refusal(config, arena, job, .no_tree);
    var subject: trust.verdict.Subject = .{
        .tree = tree,
        .binding = binding_of(job.source),
        // A job's image is a tree, never a build result: a result-bound line is another binding.
        .derives = false,
    };
    if (fault_on(.subject_from_signature)) subject = subject_of_first(scratch) orelse subject;
    const report = &scratch.report;
    const work = &scratch.work;
    const signed = trust.verdict.judge(work, config.policy, &scratch.record, subject, report);
    if (fault_on(.count_any_line) and report.count > 0) return null;
    if (!signed) return try refusal(config, arena, job, .unsigned);
    if (!trust.verdict.provenance_met(config.policy, report)) {
        return try refusal(config, arena, job, .no_provenance);
    }
    return null;
}

/// The tree of an image `b3:<64 lowercase hex>`, or null for anything else.
pub fn tree_of(image: []const u8) ?trust.statement.Digest {
    const prefix = "b3:";
    if (image.len != prefix.len + 64 or !std.mem.startsWith(u8, image, prefix)) return null;
    return digest_of_hex(image[prefix.len..]);
}

/// The binding of a job's `source` (`registry/name@sha256:<64 lowercase hex>`, as
/// `apply.source_problem` admits it): its manifest digest; none for a job without one.
pub fn binding_of(source: []const u8) trust.statement.Binding {
    if (source.len == 0) return .none;
    assert(source.len > 64);
    const digest = digest_of_hex(source[source.len - 64 ..]).?; // source_problem checked it.
    return .{ .manifest = digest };
}

fn digest_of_hex(hex: []const u8) ?trust.statement.Digest {
    assert(hex.len == 64);
    for (hex) |byte| {
        const valid = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!valid) return null;
    }
    var digest: trust.statement.Digest = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch unreachable; // Checked above.
    return digest;
}

/// The teeth's wrong subject: what the first line says of itself.
fn subject_of_first(scratch: *Scratch) ?trust.verdict.Subject {
    if (scratch.record.count == 0) return null;
    const envelope = trust.dsse.parse(&scratch.work, scratch.record.line(0)) catch return null;
    const said = trust.statement.parse(envelope.payload) catch return null;
    return .{ .tree = said.tree, .binding = said.binding, .derives = false };
}

// ---- The refusal -------------------------------------------------------------------------------

const Why = enum { unsigned, no_tree, no_provenance };

/// How many lines the refusal names, one cause each; the rest are counted (as Zigbox does).
const signatures_named_max: u32 = 4;

fn refusal(
    config: *const Trust,
    arena: std.mem.Allocator,
    job: Job,
    why: Why,
) error{OutOfMemory}!*const Diagnostic {
    const diag = try arena.create(zigbox.diag.Diag);
    diag.reset();
    const policy = config.policy;
    const path = config.path;
    const digest = job.image;
    diag.raise(if (why == .no_provenance) .E0906 else .E0905);
    diag.while_("checking {s} against the policy {s}", .{ digest, path });
    switch (why) {
        .no_tree => diag.cause("{s} requires {s}, and the image {s} is not a tree " ++
            "(b3: and 64 hex digits) that a signature can name", .{
            path, asks(policy), digest,
        }),
        .unsigned => if (config.scratch.report.count == 0) {
            diag.cause("{s} requires a signature (require_signature), and nothing has " ++
                "signed {s}", .{ path, digest });
        } else {
            diag.cause("{s} requires a signature (require_signature), and none of the {d} " ++
                "on {s} counts", .{ path, config.scratch.report.count, digest });
        },
        .no_provenance => diag.cause("{s} requires signed provenance (require_provenance), " ++
            "and no trusted provenance statement on {s} counts", .{ path, digest }),
    }
    if (why != .no_tree) name_lines(diag, config);
    diag.context("digest", "{s}", .{digest});
    diag.context("policy", "{s}", .{path});
    if (job.source.len > 0) diag.context("source", "{s}", .{job.source});
    if (why == .no_tree) {
        diag.fix(.{ .sentence = "submit the job with its image's tree digest (b3:...)" });
    } else {
        diag.fix_with("sign it with a key the policy lists:", "zbx sign {s}", .{digest});
        diag.fix(.{ .sentence = "or add the signer's key to the policy file" });
    }
    const out = try arena.create(Diagnostic);
    zigbox.diagnostic.from_diag(out, diag);
    return out;
}

fn asks(policy: *const trust.policy.Policy) []const u8 {
    if (policy.require_signature) return "a signature (require_signature)";
    return "signed provenance (require_provenance)";
}

fn name_lines(diag: *zigbox.diag.Diag, config: *const Trust) void {
    const report = &config.scratch.report;
    assert(report.count <= constants.job_signatures_max);
    const shown = @min(report.count, signatures_named_max);
    for (report.lines[0..shown]) |line| {
        const text = trust.key.public_text(line.public);
        const listed = config.policy.trusted(&line.public);
        const name: []const u8 = if (listed) |found| found.name_text() else "";
        // The first 16 hex digits identify a key to a reader, as in Zigbox's own refusal.
        const prefix_bytes = trust.key.public_prefix.len + 16;
        if (name.len > 0) {
            diag.cause("signed by '{s}': {s}", .{ name, reason_text(line.reason) });
        } else {
            diag.cause("signed by {s}: {s}", .{ text[0..prefix_bytes], reason_text(line.reason) });
        }
    }
    if (report.count > shown) {
        diag.cause("{d} more signatures are not listed", .{report.count - shown});
    }
}

/// Zigbox's words for each verdict (`trust/diagnose.zig`, `reason_text`).
pub fn reason_text(reason: trust.verdict.Reason) []const u8 {
    return switch (reason) {
        .counts => "it counts",
        .malformed => "it is not a statement this zbx can read",
        .bad_signature => "its signature does not verify",
        .untrusted_key => "the policy does not list that key",
        .other_tree => "it is about another tree",
        .other_predicate => "it says something this zbx does not know",
        .other_binding => "it is bound to another result or image than this run's",
        .not_derived => "it is bound to a result, and this image's record does not keep its " ++
            "labels, so the result it was made from cannot be checked; pull the image again",
    };
}

// ---- Tests -------------------------------------------------------------------------------------

const testing = std.testing;
const fixture_mod = @import("job_trust_fixture.zig");
const Fixture = fixture_mod.Fixture;

const trusted_seed: u8 = 1;
const stranger_seed: u8 = 2;

const Case = struct {
    fixture: Fixture,
    arena: std.heap.ArenaAllocator,
    image: [67]u8 = undefined,
    source: [128]u8 = undefined,

    fn init() !Case {
        var fixture = try Fixture.init(testing.allocator);
        errdefer fixture.deinit(testing.allocator);
        try fixture.trust_keys(&.{trusted_seed}, true);
        return .{ .fixture = fixture, .arena = .init(testing.allocator) };
    }

    fn deinit(case: *Case) void {
        case.arena.deinit();
        case.fixture.deinit(testing.allocator);
    }

    fn job(case: *Case, tree_byte: u8, manifest_byte: ?u8, lines: []const []const u8) Job {
        return .{
            .image = fixture_mod.image(&case.image, tree_byte),
            .source = if (manifest_byte) |byte| fixture_mod.source(&case.source, byte) else "",
            .signatures = lines,
        };
    }

    fn judge(case: *Case, job_value: Job) !Admission {
        const config = case.fixture.config();
        return admit(&config, case.arena.allocator(), job_value);
    }

    fn sign_tree(case: *Case, seed: u8, tree_byte: u8) ![]const u8 {
        return case.fixture.sign_tree(case.arena.allocator(), seed, tree_byte);
    }

    fn sign_manifest(case: *Case, seed: u8, tree_byte: u8, manifest_byte: u8) ![]const u8 {
        return case.fixture.sign_manifest(case.arena.allocator(), seed, tree_byte, manifest_byte);
    }
};

fn expect_refused(admission: Admission, wanted_cause: []const u8) !void {
    const refused = switch (admission) {
        .refused => |diagnostic| diagnostic,
        else => return error.TestExpectedRefusal,
    };
    try testing.expectEqualStrings("ZBX-E0905", refused.code.slice());
    for (refused.causes.slice()) |cause| {
        if (std.mem.indexOf(u8, cause.slice(), wanted_cause) != null) return;
    }
    return error.TestCauseMissing;
}

fn unsigned_refused() !void {
    var case = try Case.init();
    defer case.deinit();
    const admission = try case.judge(case.job(7, null, &.{}));
    try expect_refused(admission, "nothing has signed b3:0707");
}

fn untrusted_key_refused() !void {
    var case = try Case.init();
    defer case.deinit();
    const line = try case.sign_tree(stranger_seed, 7);
    const admission = try case.judge(case.job(7, null, &.{line}));
    try expect_refused(admission, "the policy does not list that key");
}

fn other_tree_refused() !void {
    var case = try Case.init();
    defer case.deinit();
    const line = try case.sign_tree(trusted_seed, 8);
    const admission = try case.judge(case.job(7, null, &.{line}));
    try expect_refused(admission, "signed by 'key-1': it is about another tree");
}

fn other_source_refused() !void {
    var case = try Case.init();
    defer case.deinit();
    const line = try case.sign_manifest(trusted_seed, 7, 0x51);
    const admission = try case.judge(case.job(7, 0x52, &.{line}));
    try expect_refused(admission, "it is bound to another result or image than this run's");
}

test "an unsigned image is refused with ZBX-E0905" {
    // Goal: under require_signature, a job with no signatures is refused, naming the policy.
    try unsigned_refused();
}

test "an image signed by a key the policy does not list is refused" {
    try untrusted_key_refused();
}

test "a signature over another tree is refused" {
    try other_tree_refused();
}

test "a manifest-bound signature does not count for a job with another source" {
    // Goal: M8's binding rule, unchanged: the line names manifest 0x51, the job's source 0x52.
    // A job with no source is refused too: a manifest-bound line binds a pulled image only.
    try other_source_refused();
    var case = try Case.init();
    defer case.deinit();
    const line = try case.sign_manifest(trusted_seed, 7, 0x51);
    const admission = try case.judge(case.job(7, null, &.{line}));
    try expect_refused(admission, "it is bound to another result or image than this run's");
}

test "a good signature is accepted: tree-only for any source, manifest-bound for its own" {
    var case = try Case.init();
    defer case.deinit();
    const tree_line = try case.sign_tree(trusted_seed, 7);
    try testing.expectEqual(Admission.admitted, try case.judge(case.job(7, null, &.{tree_line})));
    try testing.expectEqual(Admission.admitted, try case.judge(case.job(7, 0x51, &.{tree_line})));
    const bound = try case.sign_manifest(trusted_seed, 7, 0x51);
    try testing.expectEqual(Admission.admitted, try case.judge(case.job(7, 0x51, &.{bound})));
    // One line that counts is enough, whatever the others are.
    const stranger = try case.sign_tree(stranger_seed, 7);
    const lines = [_][]const u8{ stranger, tree_line };
    try testing.expectEqual(Admission.admitted, try case.judge(case.job(7, null, &lines)));
}

test "a policy that asks for nothing admits every job, unread" {
    var case = try Case.init();
    defer case.deinit();
    try case.fixture.trust_keys(&.{trusted_seed}, false);
    try testing.expectEqual(Admission.admitted, try case.judge(case.job(7, null, &.{})));
    try testing.expectEqual(Admission.admitted, try case.judge(case.job(7, null, &.{"x"})));
}

test "a line that is not an envelope is malformed; an image that is not a tree is refused" {
    var case = try Case.init();
    defer case.deinit();
    const good = try case.sign_tree(trusted_seed, 7);
    const lines = [_][]const u8{ good, "{\"payload\":1}" };
    const admission = try case.judge(case.job(7, null, &lines));
    try testing.expectEqual(Admission{ .malformed = 2 }, admission);
    const job_value: Job = .{ .image = "alpine", .source = "", .signatures = &.{good} };
    try expect_refused(try case.judge(job_value), "is not a tree");
}

test "the refusal names each line and the fixes, as Zigbox's run gate does" {
    var case = try Case.init();
    defer case.deinit();
    const stranger = try case.sign_tree(stranger_seed, 7);
    const other = try case.sign_tree(trusted_seed, 8);
    const lines = [_][]const u8{ stranger, other };
    const refused = (try case.judge(case.job(7, null, &lines))).refused;
    const causes = refused.causes.slice();
    try testing.expectEqual(@as(usize, 3), causes.len);
    try testing.expect(std.mem.endsWith(u8, causes[0].slice(), "none of the 2 on " ++
        "b3:0707070707070707070707070707070707070707070707070707070707070707 counts"));
    const stranger_key = fixture_mod.public_text(stranger_seed);
    var wanted: [128]u8 = undefined;
    const unlisted = "signed by {s}: the policy does not list that key";
    const first = try std.fmt.bufPrint(&wanted, unlisted, .{
        stranger_key[0 .. trust.key.public_prefix.len + 16],
    });
    try testing.expectEqualStrings(first, causes[1].slice());
    const third = "signed by 'key-1': it is about another tree";
    try testing.expectEqualStrings(third, causes[2].slice());
    try testing.expectEqualStrings("policy", refused.pairs.slice()[1].key_slice());
    const sign = "zbx sign b3:0707070707070707070707070707070707070707" ++
        "070707070707070707070707";
    try testing.expectEqualStrings(sign, refused.fixes.slice()[0].command.slice());
}

test "shape: at most four envelopes of 1 to 2048 printable bytes" {
    var buffer: [problem_bytes_max]u8 = undefined;
    const four = [_][]const u8{ "a", "b", "c", "d" };
    try testing.expectEqual(@as(?[]const u8, null), shape_problem(&buffer, &four));
    const five = four ++ [_][]const u8{"e"};
    const too_many = shape_problem(&buffer, &five).?;
    try testing.expectEqualStrings("at most 4 envelopes, there are 5", too_many);
    const long: [constants.job_signature_bytes_max + 1]u8 = @splat('a');
    try testing.expectEqualStrings(
        "envelope 1 must be 1 to 2048 bytes, it is 2049",
        shape_problem(&buffer, &.{&long}).?,
    );
    const at_bound = long[0..constants.job_signature_bytes_max];
    try testing.expect(shape_problem(&buffer, &.{at_bound}) == null);
    try testing.expect(shape_problem(&buffer, &.{""}) != null);
    const two_lines = shape_problem(&buffer, &.{"a\nb"}).?;
    try testing.expect(std.mem.indexOf(u8, two_lines, "one line") != null);
}

test "a signed envelope fits the job's bounds with room to spare" {
    // Goal: the bounds are not too tight for what zbx writes. A manifest-bound line is the
    // longest a job carries; four of them, escaped, leave room in the run record.
    var case = try Case.init();
    defer case.deinit();
    const line = try case.sign_manifest(trusted_seed, 7, 0x51);
    try testing.expect(line.len <= constants.job_signature_bytes_max / 2);
    var buffer: [problem_bytes_max]u8 = undefined;
    try testing.expect(shape_problem(&buffer, &.{line}) == null);
}

fn expect_tooth(fault: TestFault, check: *const fn () anyerror!void) !void {
    set_test_fault(fault, true);
    defer set_test_fault(fault, false);
    if (check()) |_| return error.TestToothMissed else |_| {}
}

test "teeth: with the verdict skipped, an unsigned job is admitted" {
    try expect_tooth(.skip_admission, unsigned_refused);
}

test "teeth: counting any line admits an untrusted key and another tree" {
    try expect_tooth(.count_any_line, untrusted_key_refused);
    try expect_tooth(.count_any_line, other_tree_refused);
}

test "teeth: a subject read from the signature admits another tree and another source" {
    try expect_tooth(.subject_from_signature, other_tree_refused);
    try expect_tooth(.subject_from_signature, other_source_refused);
}

test "teeth: without the bounds, five envelopes pass" {
    const check = struct {
        fn run() !void {
            var buffer: [problem_bytes_max]u8 = undefined;
            const five = [_][]const u8{ "a", "b", "c", "d", "e" };
            if (shape_problem(&buffer, &five) == null) return error.TestBoundsMissed;
        }
    }.run;
    try expect_tooth(.skip_bounds, check);
}
