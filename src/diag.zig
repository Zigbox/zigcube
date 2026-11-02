//! Zigcube's diagnostic collector: the `Diag` a function fills while it fails, bound to the
//! `ZC-` registry (`diag/codes.zig`). Its surface is Zigbox's `Diag` (`raise`, `cause`, `while_`,
//! `context`, `fix`, `fix_with`, `entry`, `exit_code`, `last_cause`); the item types (`Text`,
//! `Pair`, `Fix`) are Zigbox's own, so a finished collector becomes a
//! `zigbox.diagnostic.Diagnostic` by copying arrays. That is the type that crosses every
//! boundary (the store, the API, `zcube why`), for `ZC-` and `ZBX-` codes alike, and
//! `zigbox.render.render_diagnostic` renders it.
//!
//! Zigbox's collector is typed to its own registry and keeps its list type private, so the
//! collector stays here; docs/diagnostics-zigbox-proposal.md explains why. Nothing here formats
//! text for the user: rendering happens at the CLI and API boundary (`render`, below).
//!
//! The collector is fixed-size and never allocates, and every byte stored is printable ASCII.
//! It is several kilobytes: initialise it in place with `reset`, pass it as `*Diag`.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const constants = @import("constants.zig");
const codes = @import("diag/codes.zig");
const text_util = @import("text.zig");

pub const Diagnostic = zigbox.diagnostic.Diagnostic;
pub const Product = zigbox.product.Product;

pub const Text = zigbox.diag.Text;
pub const Command = zigbox.diag.Command;
pub const Pair = zigbox.diag.Pair;
pub const Fix = zigbox.diag.Fix;
pub const FixOptions = zigbox.diag.FixOptions;

/// Zigcube's strings of a diagnostic. Zigbox's renderer picks a product by the prefix of the code
/// it renders, so a `ZBX-` diagnostic that reaches `zcube why` still says `zbx explain`.
pub const product: Product = .{
    .prefix = "ZC-",
    .command = "zcube",
    .bundle_hint = "zcube bundle --last",
    .report_url = "https://github.com/Zigbox/zigcube/issues/new",
    .docs_url_base = "https://zigbox.github.io/zigcube/errors/",
};

/// Every product whose codes may appear in a diagnostic Zigcube shows.
pub const products = [_]Product{ product, Product.zbx };

comptime {
    // The shared item types carry Zigbox's bounds; Zigcube's constants must say the same.
    assert(@typeInfo(@FieldType(Text, "bytes")).array.len == constants.diag_field_bytes_max);
    assert(@typeInfo(@FieldType(Command, "bytes")).array.len == constants.diag_command_bytes_max);
    assert(@typeInfo(@FieldType(Pair, "key")).array.len == constants.diag_key_bytes_max);
    const finished: Diagnostic = undefined;
    const causes = @typeInfo(@TypeOf(finished.causes.items)).array.len;
    assert(causes == constants.diag_causes_count_max);
    assert(@typeInfo(@TypeOf(finished.whiles.items)).array.len == constants.diag_whiles_count_max);
    assert(@typeInfo(@TypeOf(finished.pairs.items)).array.len == constants.diag_context_count_max);
    assert(@typeInfo(@TypeOf(finished.fixes.items)).array.len == constants.diag_fixes_count_max);
}

/// Which end of a full list survives a new item.
const Keep = enum { oldest, newest };

pub fn List(comptime Item: type, comptime capacity: u32, comptime keep: Keep) type {
    comptime assert(capacity > 0);
    return struct {
        const Self = @This();
        items: [capacity]Item = undefined,
        count: u32 = 0,
        /// Items that did not fit (or that replaced the last slot). Shown as an omitted note.
        omitted: u32 = 0,

        fn reset(list: *Self) void {
            list.count = 0;
            list.omitted = 0;
            assert(list.slice().len == 0);
        }

        /// The slot to fill, or null if the list is full and keeps its oldest items. The
        /// caller initialises the slot completely.
        fn next(list: *Self) ?*Item {
            assert(list.count <= capacity);
            if (list.count == capacity) {
                assert(list.omitted < std.math.maxInt(u32));
                list.omitted += 1;
                if (keep == .oldest) return null;
                return &list.items[capacity - 1];
            }
            list.count += 1;
            assert(list.count <= capacity);
            return &list.items[list.count - 1];
        }

        pub fn slice(list: *const Self) []const Item {
            assert(list.count <= capacity);
            if (list.omitted > 0) assert(list.count == capacity);
            return list.items[0..list.count];
        }
    };
}

pub const Causes = List(Text, constants.diag_causes_count_max, .newest);
pub const Whiles = List(Text, constants.diag_whiles_count_max, .newest);
pub const Pairs = List(Pair, constants.diag_context_count_max, .oldest);
pub const Fixes = List(Fix, constants.diag_fixes_count_max, .oldest);

pub const Diag = struct {
    code: ?codes.Code,
    causes: Causes,
    whiles: Whiles,
    pairs: Pairs,
    fixes: Fixes,
    /// The path of the bundle written for this bug, empty for none. Only a bug has one.
    saved: zigbox.diag.Saved,
    /// True when the failure hit a write whose outcome is unknown (a connection lost during a
    /// COMMIT): the write may have applied. A structural signal, so rewording a cause cannot
    /// change how a caller treats the failure; it is never rendered.
    write_outcome_unknown: bool,

    /// Initialises in place: the struct is several kilobytes.
    pub fn reset(diag: *Diag) void {
        diag.code = null;
        diag.causes.reset();
        diag.whiles.reset();
        diag.pairs.reset();
        diag.fixes.reset();
        diag.saved = .{};
        diag.write_outcome_unknown = false;
        assert(diag.saved.len == 0);
        assert(diag.causes.count == 0);
        assert(diag.code == null);
        assert(!diag.write_outcome_unknown);
    }

    /// Records where the bundle for this bug was written.
    pub fn save_bundle(diag: *Diag, path: []const u8) void {
        assert(diag.code != null);
        assert(path.len > 0);
        diag.saved = .{};
        diag.saved.print("{s}", .{path});
        assert(diag.saved.len > 0);
    }

    /// Classifies the failure. Once per diagnostic: two classifications would mean two layers
    /// each believe they own the failure, and the user would see only one of them.
    pub fn raise(diag: *Diag, code: codes.Code) void {
        assert(diag.code == null);
        diag.code = code;
        assert(diag.code.? == code);
    }

    pub fn cause(diag: *Diag, comptime format: []const u8, args: anytype) void {
        const slot = diag.causes.next().?; // `.newest` lists always have a slot.
        slot.* = .{};
        put(slot, format, args);
        assert(slot.len > 0);
        assert(slot.len <= constants.diag_field_bytes_max);
        assert(diag.causes.count > 0);
    }

    pub fn while_(diag: *Diag, comptime format: []const u8, args: anytype) void {
        const slot = diag.whiles.next().?; // `.newest` lists always have a slot.
        slot.* = .{};
        put(slot, format, args);
        assert(slot.len > 0);
        assert(slot.len <= constants.diag_field_bytes_max);
        assert(diag.whiles.count > 0);
    }

    /// Adds a labelled fact, for example `diag.context("path", "{s}", .{path})`. The key is a
    /// comptime string so that a bad one does not compile.
    pub fn context(
        diag: *Diag,
        comptime key: []const u8,
        comptime format: []const u8,
        args: anytype,
    ) void {
        comptime check_key(key);
        const slot = diag.pairs.next() orelse return;
        slot.key = @splat(0);
        @memcpy(slot.key[0..key.len], key);
        slot.key_len = key.len;
        slot.value = .{};
        put(&slot.value, format, args);
        assert(slot.value.len > 0);
        assert(slot.key_len == key.len);
        assert(diag.pairs.count > 0);
    }

    pub fn fix(diag: *Diag, options: FixOptions) void {
        assert(options.sentence.len > 0);
        assert(options.command.len <= constants.diag_command_bytes_max * 4); // Cut by `put`.
        const slot = diag.fixes.next() orelse return;
        slot.sentence = .{};
        slot.command = .{};
        put(&slot.sentence, "{s}", .{options.sentence});
        if (options.command.len > 0) put(&slot.command, "{s}", .{options.command});
        assert(slot.sentence.len > 0);
    }

    /// A fix whose command is built from run-time text, for example the name of the command that
    /// was misused. The sentence is fixed prose; the command is formatted and sanitised.
    pub fn fix_with(
        diag: *Diag,
        sentence: []const u8,
        comptime command_format: []const u8,
        command_args: anytype,
    ) void {
        assert(sentence.len > 0);
        const slot = diag.fixes.next() orelse return;
        slot.sentence = .{};
        slot.command = .{};
        put(&slot.sentence, "{s}", .{sentence});
        put(&slot.command, command_format, command_args);
        assert(slot.command.len > 0);
    }

    /// The registry entry for the classified code. Asserts that `raise` was called.
    pub fn entry(diag: *const Diag) *const codes.Entry {
        assert(diag.code != null);
        const found = codes.entry(diag.code.?);
        assert(found.summary.len > 0);
        return found;
    }

    /// The process exit code for this failure, decided by the code's blame and nothing else.
    pub fn exit_code(diag: *const Diag) u8 {
        const blame = diag.entry().blame;
        const exit = codes.exit_code(blame);
        assert(exit != constants.exit_ok);
        assert(diag.code != null);
        return exit;
    }

    /// The newest cause: the one default output shows. Null if none was added.
    pub fn last_cause(diag: *const Diag) ?[]const u8 {
        assert(diag.causes.count <= constants.diag_causes_count_max);
        if (diag.causes.count == 0) return null;
        const text = diag.causes.items[diag.causes.count - 1].slice();
        assert(text.len > 0);
        return text;
    }
};

/// Copies a finished collector. Initialises `out` in place (it is several kilobytes), and points
/// its docs at Zigcube's page for the code.
pub fn to_diagnostic(out: *Diagnostic, diag: *const Diag) void {
    assert(diag.code != null);
    const registered = diag.entry();
    out.reset();
    out.code.print("{s}", .{codes.full_name(registered.code)});
    out.severity = registered.severity;
    out.blame = registered.blame;
    out.summary.print("{s}", .{registered.summary});
    assert(!out.summary.truncated); // The registry's comptime check bounds every summary.
    copy_list(&out.causes, &diag.causes);
    copy_list(&out.whiles, &diag.whiles);
    copy_list(&out.pairs, &diag.pairs);
    copy_list(&out.fixes, &diag.fixes);
    out.saved.print("{s}", .{diag.saved.slice()});
    out.set_docs(&product);
    assert(out.code.len > 0);
}

/// Copies the used items only, so no byte that was never written is read.
fn copy_list(target: anytype, source: anytype) void {
    assert(source.count <= source.items.len);
    target.* = .{ .count = source.count, .omitted = source.omitted };
    @memcpy(target.items[0..source.count], source.items[0..source.count]);
    assert(target.slice().len == source.slice().len);
}

/// Renders a finished diagnostic of either product into `buffer` (`diag_output_bytes_max` bytes)
/// and returns the used prefix.
pub fn render(
    diagnostic: *const Diagnostic,
    mode: zigbox.render.Mode,
    color: bool,
    buffer: []u8,
) []const u8 {
    assert(buffer.len >= constants.diag_output_bytes_max);
    assert(diagnostic.code.len > 0);
    return zigbox.render.render_diagnostic(diagnostic, &products, mode, color, buffer);
}

/// The text of `zcube explain <code>`, built from Zigcube's registry and laid out by Zigbox's
/// renderer, so the two products' `explain` cannot drift apart.
pub fn explain(code: codes.Code, buffer: []u8) []const u8 {
    assert(buffer.len >= constants.diag_output_bytes_max);
    const registered = codes.entry(code);
    var exit_buffer: [zigbox.codes.exit_text_bytes_max]u8 = undefined;
    const exit_text = std.fmt.bufPrint(&exit_buffer, "{d}", .{codes.exit_code(registered.blame)});
    return zigbox.explain.render_entry(.{
        .full_name = codes.full_name(code),
        .severity = registered.severity,
        .blame = registered.blame,
        .summary = registered.summary,
        .explanation = registered.explanation,
        // Cannot fail: an exit code is at most three digits, and the buffer holds forty bytes.
        .exit_text = exit_text catch unreachable,
    }, buffer);
}

fn check_key(comptime key: []const u8) void {
    comptime {
        assert(key.len > 0);
        assert(key.len <= constants.diag_key_bytes_max);
        for (key) |byte| assert(std.ascii.isLower(byte));
        // The renderer uses these as labels of its own.
        const reserved = [_][]const u8{ "while", "cause", "fix", "more", "report" };
        for (reserved) |word| assert(!std.mem.eql(u8, key, word));
    }
}

/// Appends formatted text to a field and makes the new bytes safe to show. A field that
/// overflows ends in "..." (Bounded does that); the sanitising pass runs on what was added.
fn put(field: anytype, comptime format: []const u8, args: anytype) void {
    const start = field.len;
    field.print(format, args);
    assert(field.len >= start);
    for (field.bytes[start..field.len]) |*byte| {
        if (!text_util.is_printable(byte.*)) byte.* = '?';
    }
    // A field is never empty, so no renderer has to cope with a labelled nothing.
    if (field.len == 0) field.print("(empty)", .{});
    assert(field.len > 0);
}

const testing = std.testing;

const repeat = @import("test_util.zig").repeat;

test "a diagnostic collects causes, whiles, context and fixes in order" {
    // Goal: the data model of the standard. Causes keep insertion order (symptom first, real
    // cause last), the exit code follows the blame, and the last cause is what default shows.
    var diag: Diag = undefined;
    diag.reset();
    try testing.expect(diag.code == null);
    try testing.expect(diag.last_cause() == null);
    diag.raise(.E0203);
    diag.cause("symptom {d}", .{1});
    diag.cause("real cause", .{});
    diag.while_("doing {s}", .{"a thing"});
    diag.context("path", "{s}", .{"/x"});
    diag.fix(.{ .sentence = "do this:", .command = "zcube help" });
    diag.fix(.{ .sentence = "or just think" });

    try testing.expectEqual(@as(u8, constants.exit_user), diag.exit_code());
    try testing.expectEqualStrings("real cause", diag.last_cause().?);
    try testing.expectEqualStrings("symptom 1", diag.causes.slice()[0].slice());
    try testing.expectEqualStrings("doing a thing", diag.whiles.slice()[0].slice());
    try testing.expectEqualStrings("path", diag.pairs.slice()[0].key_slice());
    try testing.expectEqualStrings("zcube help", diag.fixes.slice()[0].command.slice());
    try testing.expectEqual(@as(usize, 0), diag.fixes.slice()[1].command.slice().len);
}

test "text is sanitised on the way in and cut with a marker at the bound" {
    // Goal: the negative space. Control bytes and non-ASCII never reach a renderer; a field one
    // byte over its bound ends in "..." and one at the bound does not.
    var diag: Diag = undefined;
    diag.reset();
    diag.raise(.E0201);
    diag.cause("a{s}b", .{"\x1b[31m\xff\x00"});
    try testing.expectEqualStrings("a?[31m??b", diag.last_cause().?);

    const exact = repeat('x', constants.diag_field_bytes_max);
    diag.cause("{s}", .{exact});
    try testing.expectEqualStrings(exact, diag.last_cause().?);
    diag.cause("{s}y", .{exact});
    const cut = diag.last_cause().?;
    try testing.expectEqual(@as(usize, constants.diag_field_bytes_max), cut.len);
    try testing.expect(std.mem.endsWith(u8, cut, "..."));
}

test "lists keep the newest cause and the oldest fix when full" {
    // Goal: the overflow policy. Past the bound the real (newest) cause still shows, the count
    // of what did not fit is exact, and nothing is written outside the arrays.
    var diag: Diag = undefined;
    diag.reset();
    diag.raise(.E0201);
    const extra = 3;
    for (0..constants.diag_causes_count_max + extra) |index| {
        diag.cause("cause {d}", .{index});
    }
    try testing.expectEqual(@as(u32, constants.diag_causes_count_max), diag.causes.count);
    try testing.expectEqual(@as(u32, extra), diag.causes.omitted);
    try testing.expectEqualStrings("cause 8", diag.last_cause().?);
    try testing.expectEqualStrings("cause 0", diag.causes.slice()[0].slice());

    for (0..constants.diag_fixes_count_max + extra) |index| {
        diag.fix(.{ .sentence = "fix", .command = if (index == 0) "first" else "later" });
    }
    try testing.expectEqual(@as(u32, constants.diag_fixes_count_max), diag.fixes.count);
    try testing.expectEqual(@as(u32, extra), diag.fixes.omitted);
    try testing.expectEqualStrings("first", diag.fixes.slice()[0].command.slice());

    for (0..constants.diag_context_count_max + 1) |_| diag.context("k", "v", .{});
    try testing.expectEqual(@as(u32, 1), diag.pairs.omitted);
}

test "reset clears everything, including the code" {
    var diag: Diag = undefined;
    diag.reset();
    diag.raise(.B0001);
    diag.cause("x", .{});
    diag.reset();
    try testing.expect(diag.code == null);
    try testing.expectEqual(@as(u32, 0), diag.causes.count);
    diag.raise(.E0203); // Allowed again: reset starts a new diagnostic.
    try testing.expectEqual(@as(u8, constants.exit_user), diag.exit_code());
}

fn image_not_found(out: *Diagnostic) void {
    // A diagnostic as it arrives from a node: the code is text of Zigbox's registry (ZBX-E0501 is
    // the one HANDOFF's demo shows), which Zigcube's collector could never raise itself.
    out.reset();
    out.code.print("ZBX-E0501", .{});
    out.severity = .@"error";
    out.blame = .user;
    out.summary.print("image not found", .{});
    out.causes.count = 1;
    out.causes.items[0] = .{};
    out.causes.items[0].print("digest b3:00ff is not in this node's store", .{});
    out.fixes.count = 1;
    out.fixes.items[0] = .{ .sentence = .{}, .command = .{} };
    out.fixes.items[0].sentence.print("check the digest in broken.zon", .{});
    out.set_docs(&Product.zbx);
}

test "a diagnostic keeps the code, blame and causes of the collector it came from" {
    // Goal: the copy loses nothing the renderer needs. Method: fill a collector, copy it,
    // compare the text fields, the exit code and the docs page.
    var diag: Diag = undefined;
    diag.reset();
    diag.raise(.E0201);
    diag.cause("connection refused", .{});
    diag.cause("postgres at 127.0.0.1:5432 is not accepting connections", .{});
    diag.fix(.{ .sentence = "start it", .command = "pg_ctl start" });

    var diagnostic: Diagnostic = undefined;
    to_diagnostic(&diagnostic, &diag);
    try testing.expectEqualStrings("ZC-E0201", diagnostic.code.slice());
    try testing.expectEqualStrings("can't reach the store backend", diagnostic.summary.slice());
    try testing.expectEqual(codes.Blame.external, diagnostic.blame);
    try testing.expectEqual(@as(u32, 2), diagnostic.causes.count);
    try testing.expectEqualStrings("pg_ctl start", diagnostic.fixes.slice()[0].command.slice());
    try testing.expectEqual(diag.exit_code(), diagnostic.exit_code());
    const docs = "https://zigbox.github.io/zigcube/errors/E0201.html";
    try testing.expectEqualStrings(docs, diagnostic.docs.slice());
}

test "each product's diagnostic renders with its own commands and links" {
    // Goal: the ZBX- diagnostic inside a ZC- failure keeps Zigbox's `zbx explain` and docs page,
    // and the ZC- one gets Zigcube's. Method: render one of each through `render`, in text and
    // verbose, and compare the `more` and `docs` lines.
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    var diag: Diag = undefined;
    diag.reset();
    diag.raise(.E0201);
    diag.cause("connection refused", .{});
    diag.fix(.{ .sentence = "start it", .command = "pg_ctl start" });
    var own: Diagnostic = undefined;
    to_diagnostic(&own, &diag);
    try testing.expectEqualStrings(
        "error[ZC-E0201]: can't reach the store backend\n" ++
            "  cause  connection refused\n" ++
            "  fix    start it   pg_ctl start\n" ++
            "  more   zcube explain E0201 \u{b7} rerun with --verbose for the full cause chain\n" ++
            "  docs   https://zigbox.github.io/zigcube/errors/E0201.html\n",
        render(&own, .text, false, &buffer),
    );

    var foreign: Diagnostic = undefined;
    image_not_found(&foreign);
    try testing.expectEqualStrings(
        "error[ZBX-E0501]: image not found\n" ++
            "  cause  digest b3:00ff is not in this node's store\n" ++
            "  fix    check the digest in broken.zon\n" ++
            "  more   zbx explain E0501 \u{b7} rerun with --verbose for the full cause chain\n" ++
            "  docs   https://zigbox.github.io/zigbox/errors/E0501.html\n",
        render(&foreign, .text, false, &buffer),
    );
}

test "a ZBX- diagnostic survives the wire and still renders with Zigbox's links" {
    // Goal: the path a node's failure takes (runtime, store or API, `zcube why`). Method: write
    // the JSON one-liner, parse it back, and compare both the value and its rendering. Then a
    // code of an unknown product renders without `more` and `docs` lines.
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    var original: Diagnostic = undefined;
    image_not_found(&original);
    var writer = std.Io.Writer.fixed(&buffer);
    try zigbox.diagnostic.write_json(&writer, &original);
    const wire = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, wire, "\"ZBX-E0501\"") != null);

    var parsed: Diagnostic = undefined;
    try zigbox.diagnostic.parse_json(&parsed, wire);
    parsed.set_docs(&Product.zbx);
    try testing.expect(parsed.equal(&original));

    var text: [constants.diag_output_bytes_max]u8 = undefined;
    const shown = render(&parsed, .verbose, false, &text);
    try testing.expect(std.mem.indexOf(u8, shown, "zbx explain E0501") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "zigbox/errors/E0501.html") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "zcube explain") == null);

    parsed.code = .{};
    parsed.code.print("ZZ-E0001", .{});
    const unknown = render(&parsed, .text, false, &text);
    try testing.expect(std.mem.indexOf(u8, unknown, "error[ZZ-E0001]") != null);
    try testing.expect(std.mem.indexOf(u8, unknown, "  more") == null);
}

test "zcube explain uses Zigbox's layout over Zigcube's registry" {
    // Goal: the header, the blame line and the explanation of a ZC- code, as `zbx explain` would
    // lay them out. Method: compare the first lines, and check every registered code renders.
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const shown = explain(.E0201, &buffer);
    const header = "ZC-E0201: can't reach the store backend\nerror, blame: external, exit code 3\n";
    try testing.expect(std.mem.startsWith(u8, shown, header));
    try testing.expect(std.mem.indexOf(u8, shown, "The control-plane store") != null);
    for (codes.registry) |item| {
        const text = explain(item.code, &buffer);
        try testing.expect(std.mem.startsWith(u8, text, codes.full_name(item.code)));
    }
}
