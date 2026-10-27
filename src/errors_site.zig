//! Build-host tool behind `zig build errors-site`: writes `site/errors/<code>.html`, one static
//! page per registered `ZC-` diagnostic code, and an index, from the registry in `diag/codes.zig`
//! (DIAGNOSTICS.md, "Codes"). A port of Zigbox's `errors_site.zig`: the pages are plain HTML with
//! inline CSS that reuses the tokens of `site/index.html`, so they work from any static host with
//! no script, and they are the `docs` link of every `ZC-` diagnostic.
//!
//!   errors_site <directory>            write the pages
//!   errors_site <directory> --check    fail, naming the first stale page, if any page differs
//!                                      from what the registry generates (CI runs this)
//!
//! Rendering is pure (a registry entry in, bytes out, into a caller's buffer) so it is tested
//! without touching the disk. The explanation text is the same text `zcube explain` prints.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const codes = @import("diag/codes.zig");

const site_url = "https://zigbox.github.io/zigcube/";

const head_start =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    \\
;

const head_fonts =
    \\<link rel="preconnect" href="https://fonts.googleapis.com">
    \\<link rel="stylesheet" href="
;

const fonts_url = "https://fonts.googleapis.com/css2?family=Familjen+Grotesk:wght@500;700" ++
    "&amp;family=IBM+Plex+Sans:wght@400;500;600" ++
    "&amp;family=IBM+Plex+Mono:wght@400;500&amp;display=swap";

const head_end =
    \\">
    \\<style>
    \\:root{color-scheme:light}
    \\:root{
    \\  --bg:#f3f5f8; --surface:#ffffff; --fg:#151a24; --muted:#5d6676; --line:#dde2ea;
    \\  --accent:#2156b8; --term:#141925; --term-fg:#e3e8f2; --term-accent:#7fa8f5;
    \\  --display:"Familjen Grotesk", "Helvetica Neue", Arial, sans-serif;
    \\  --body:"IBM Plex Sans", "Helvetica Neue", Arial, sans-serif;
    \\  --mono:"IBM Plex Mono", ui-monospace, "SFMono-Regular", Menlo, monospace;
    \\}
    \\@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){
    \\  --bg:#0f131b; --surface:#161b25; --fg:#e3e8f2; --muted:#98a1b3; --line:#262d3a;
    \\  --accent:#7fa8f5; --term:#0a0d13; color-scheme:dark}}
    \\:root[data-theme="dark"]{
    \\  --bg:#0f131b; --surface:#161b25; --fg:#e3e8f2; --muted:#98a1b3; --line:#262d3a;
    \\  --accent:#7fa8f5; --term:#0a0d13; color-scheme:dark}
    \\*{box-sizing:border-box}
    \\body{background:var(--bg);color:var(--fg);font-family:var(--body);font-size:16px;
    \\  line-height:1.6;margin:0}
    \\.wrap{max-width:760px;margin:0 auto;padding-left:max(16px,env(safe-area-inset-left,0px));
    \\  padding-right:max(16px,env(safe-area-inset-right,0px))}
    \\a{color:var(--accent)} a:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
    \\h1,h2{font-family:var(--display);line-height:1.15;margin:0;text-wrap:balance}
    \\h1{font-size:clamp(2rem,6vw,2.8rem);font-family:var(--mono);font-weight:500;
    \\  letter-spacing:-.01em}
    \\h2{font-size:1.3rem;margin:32px 0 8px}
    \\code,pre{font-family:var(--mono);font-size:.9em}
    \\.eyebrow{font-family:var(--mono);font-size:.75rem;letter-spacing:.08em;
    \\  text-transform:uppercase;color:var(--muted)}
    \\header.top{border-bottom:1px solid var(--line)}
    \\header.top .wrap{display:flex;align-items:center;gap:20px;padding-block:12px;flex-wrap:wrap}
    \\.brand{font-family:var(--display);font-weight:700;font-size:1.2rem;color:var(--fg);
    \\  text-decoration:none;display:flex;gap:8px;align-items:center}
    \\.brand .mark{width:20px;height:20px;border:2px solid var(--accent);border-radius:3px;
    \\  position:relative}
    \\.brand .mark::after{content:"";position:absolute;inset:4px;background:var(--accent);
    \\  border-radius:1px}
    \\nav{margin-left:auto;font-size:.9rem}
    \\main{padding-block:40px 56px}
    \\.summary{font-size:1.25rem;margin:10px 0 24px}
    \\.facts{display:flex;gap:32px;flex-wrap:wrap;margin:0 0 8px;padding:16px 0;
    \\  border-block:1px solid var(--line)}
    \\.facts div{min-width:0} .facts dt{font-family:var(--mono);font-size:.72rem;
    \\  letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
    \\.facts dd{margin:2px 0 0;font-family:var(--mono)}
    \\p{margin:0 0 14px;max-width:68ch}
    \\.term{background:var(--term);color:var(--term-fg);border-radius:10px;margin:0;
    \\  padding:12px 16px;overflow-x:auto;white-space:pre}
    \\table{border-collapse:collapse;width:100%}
    \\th,td{text-align:left;padding:8px 12px 8px 0;border-bottom:1px solid var(--line);
    \\  vertical-align:top}
    \\th{font-family:var(--mono);font-size:.72rem;letter-spacing:.08em;text-transform:uppercase;
    \\  color:var(--muted);font-weight:500}
    \\td.code{font-family:var(--mono);white-space:nowrap}
    \\footer{border-top:1px solid var(--line);padding-block:24px;color:var(--muted);
    \\  font-size:.85rem}
    \\</style>
    \\</head>
    \\<body>
    \\<header class="top"><div class="wrap">
    \\  <a class="brand" href="../"><span class="mark" aria-hidden="true"></span>Zigcube</a>
    \\  <nav aria-label="Diagnostics"><a href="./">All diagnostic codes</a></nav>
    \\</div></header>
    \\<main class="wrap">
    \\
;

const foot =
    \\</main>
    \\<footer><div class="wrap">
    \\Generated from the diagnostic registry by <code>zig build errors-site</code>.
    \\The same text is printed offline by <code>zcube explain</code>.
    \\</div></footer>
    \\</body>
    \\</html>
    \\
;

// The writer is a fixed buffer that `constants.zig` proves holds a maximal page, so a write to
// it cannot fail. These two helpers are the only places that say so.

fn emit(writer: *std.Io.Writer, bytes: []const u8) void {
    assert(writer.buffer.len >= constants.errors_page_bytes_max);
    assert(bytes.len <= constants.errors_page_bytes_max);
    writer.writeAll(bytes) catch unreachable; // Cannot fail: the buffer holds a maximal page.
}

fn emit_format(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) void {
    assert(writer.buffer.len >= constants.errors_page_bytes_max);
    assert(format.len > 0);
    writer.print(format, args) catch unreachable; // Cannot fail: same bound as `emit`.
}

/// Writes `text` with the characters HTML gives meaning to escaped.
fn write_escaped(writer: *std.Io.Writer, text: []const u8) void {
    assert(text.len <= constants.diag_explanation_bytes_max);
    assert(std.mem.indexOfScalar(u8, text, 0) == null);
    for (text) |byte| {
        switch (byte) {
            '&' => emit(writer, "&amp;"),
            '<' => emit(writer, "&lt;"),
            '>' => emit(writer, "&gt;"),
            '"' => emit(writer, "&quot;"),
            else => emit(writer, &.{byte}),
        }
    }
}

/// Writes the explanation as paragraphs: a blank line starts a new one, and the hard-wrapped
/// lines within one flow together.
fn write_paragraphs(writer: *std.Io.Writer, explanation: []const u8) void {
    assert(explanation.len > 0);
    assert(explanation[explanation.len - 1] != '\n');
    var lines = std.mem.splitScalar(u8, explanation, '\n');
    var open = false;
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (open) emit(writer, "</p>\n");
            open = false;
            continue;
        }
        emit(writer, if (open) " " else "<p>");
        open = true;
        write_escaped(writer, line);
    }
    if (open) emit(writer, "</p>\n");
}

fn write_head(
    writer: *std.Io.Writer,
    title: []const u8,
    summary: []const u8,
    file: []const u8,
) void {
    assert(title.len > 0);
    assert(file.len > 0);
    emit(writer, head_start);
    emit_format(writer, "<title>{s} \u{b7} Zigcube</title>\n", .{title});
    emit(writer, "<meta name=\"description\" content=\"");
    write_escaped(writer, summary);
    emit_format(writer, "\">\n<link rel=\"canonical\" href=\"" ++ site_url ++ "errors/{s}\">\n", .{
        file,
    });
    emit(writer, head_fonts ++ fonts_url ++ head_end);
}

/// The page of one code. `buffer` must be `constants.errors_page_bytes_max` bytes.
pub fn render_page(code: codes.Code, buffer: []u8) []const u8 {
    assert(buffer.len >= constants.errors_page_bytes_max);
    const entry = codes.entry(code);
    var writer = std.Io.Writer.fixed(buffer);
    var file_buffer: [16]u8 = undefined;
    write_head(&writer, codes.full_name(code), entry.summary, page_name(&file_buffer, code));
    emit_format(&writer, "<p class=\"eyebrow\">Diagnostic code</p>\n<h1>{s}</h1>\n", .{
        codes.full_name(code),
    });
    emit(&writer, "<p class=\"summary\">");
    write_escaped(&writer, entry.summary);
    emit(&writer, "</p>\n");
    var exit_buffer: [8]u8 = undefined;
    const exit_code = codes.exit_code(entry.blame);
    // Cannot fail: an exit code is at most three digits.
    const exit_text = std.fmt.bufPrint(&exit_buffer, "{d}", .{exit_code}) catch unreachable;
    emit_format(
        &writer,
        "<dl class=\"facts\">" ++
            "<div><dt>Kind</dt><dd>{s}</dd></div>" ++
            "<div><dt>Blame</dt><dd>{s}</dd></div>" ++
            "<div><dt>Exit code</dt><dd>{s}</dd></div></dl>\n",
        .{ @tagName(entry.severity), @tagName(entry.blame), exit_text },
    );
    emit(&writer, "<h2>What it means</h2>\n");
    write_paragraphs(&writer, entry.explanation);
    emit_format(
        &writer,
        "<h2>Offline</h2>\n<p>The same text, without a network:</p>\n" ++
            "<pre class=\"term\">zcube explain {s}</pre>\n",
        .{@tagName(code)},
    );
    emit(&writer, foot);
    const page = writer.buffered();
    assert(std.mem.endsWith(u8, page, "</html>\n"));
    return page;
}

/// The index: every code, its summary, blame and a link to its page.
pub fn render_index(buffer: []u8) []const u8 {
    assert(buffer.len >= constants.errors_page_bytes_max);
    assert(codes.registry.len > 0);
    var writer = std.Io.Writer.fixed(buffer);
    write_head(&writer, "Diagnostic codes", "Every diagnostic code zcube can show", "index.html");
    emit(&writer, "<p class=\"eyebrow\">Reference</p>\n<h1>Diagnostic codes</h1>\n");
    emit(&writer, "<p class=\"summary\">Every failure zcube reports has one of these codes. ");
    emit(&writer, "<code>zcube explain &lt;code&gt;</code> prints the same text offline.</p>\n");
    emit(&writer, "<table>\n<tr><th>Code</th><th>Summary</th><th>Blame</th></tr>\n");
    for (codes.registry) |entry| {
        var file_buffer: [16]u8 = undefined;
        const file = page_name(&file_buffer, entry.code);
        emit_format(&writer, "<tr><td class=\"code\"><a href=\"{s}\">{s}</a></td><td>", .{
            file, codes.full_name(entry.code),
        });
        write_escaped(&writer, entry.summary);
        emit_format(&writer, "</td><td>{s}</td></tr>\n", .{@tagName(entry.blame)});
    }
    emit(&writer, "</table>\n");
    emit(&writer, foot);
    const page = writer.buffered();
    assert(std.mem.endsWith(u8, page, "</html>\n"));
    return page;
}

/// "E0102.html": the file name of a code's page, as the `docs` link of a diagnostic names it.
fn page_name(buffer: *[16]u8, code: codes.Code) []const u8 {
    // Cannot fail: a tag is five bytes.
    const name = std.fmt.bufPrint(buffer, "{s}.html", .{@tagName(code)}) catch unreachable;
    assert(std.mem.endsWith(u8, name, ".html"));
    return name;
}

const Mode = enum { write, check };

const usage_text = "usage: errors_site <directory> [--check]\n";

pub fn main(init: std.process.Init) !u8 {
    var out_buffer: [1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &out_buffer);
    const out = &file_writer.interface;
    defer out.flush() catch {}; // Nowhere else to report.

    var iterator = init.minimal.args.iterate();
    _ = iterator.next();
    const directory = iterator.next() orelse return usage(out);
    var mode: Mode = .write;
    if (iterator.next()) |flag| {
        if (!std.mem.eql(u8, flag, "--check")) return usage(out);
        mode = .check;
    }
    if (iterator.next() != null) return usage(out);

    const io = init.io;
    if (mode == .write) try std.Io.Dir.cwd().createDirPath(io, directory);
    var page_buffer: [constants.errors_page_bytes_max]u8 = undefined;
    var stale: u32 = 0;
    var count: u32 = 0;
    for (codes.registry) |entry| {
        var file_buffer: [16]u8 = undefined;
        const page = render_page(entry.code, &page_buffer);
        const file = page_name(&file_buffer, entry.code);
        stale += try handle(init, out, mode, directory, file, page);
        count += 1;
    }
    const index = render_index(&page_buffer);
    stale += try handle(init, out, mode, directory, "index.html", index);
    count += 1;
    assert(count == codes.registry.len + 1);
    if (stale > 0) return constants.exit_user;
    try out.print("errors_site: {d} pages {s} in {s}\n", .{
        count, if (mode == .write) "written" else "up to date", directory,
    });
    return constants.exit_ok;
}

/// Writes one page, or in check mode compares it with the file on disk. Returns 1 if the page
/// on disk is missing or differs (a one-line message names it), 0 otherwise.
fn handle(
    init: std.process.Init,
    out: *std.Io.Writer,
    mode: Mode,
    directory: []const u8,
    file: []const u8,
    page: []const u8,
) !u32 {
    assert(page.len > 0);
    assert(page.len <= constants.errors_page_bytes_max);
    var path_buffer: [constants.state_path_bytes_max]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, file });
    const cwd = std.Io.Dir.cwd();
    if (mode == .write) {
        try cwd.writeFile(init.io, .{ .sub_path = path, .data = page });
        return 0;
    }
    const limit: std.Io.Limit = .limited(constants.errors_page_bytes_max);
    const existing = cwd.readFileAlloc(init.io, path, init.arena.allocator(), limit) catch {
        try out.print("errors_site: {s} is missing; run: zig build errors-site\n", .{path});
        return 1;
    };
    if (std.mem.eql(u8, existing, page)) return 0;
    try out.print("errors_site: {s} is stale; run: zig build errors-site\n", .{path});
    return 1;
}

fn usage(out: *std.Io.Writer) u8 {
    out.writeAll(usage_text) catch {}; // Nowhere else to report.
    return constants.exit_environment;
}

const testing = std.testing;

test "every code has a page that names it and carries its explanation" {
    // Goal: the page is the registry's data, escaped, and well formed enough to be static HTML.
    // Method: render every code and look for its code, summary and explanation text.
    var buffer: [constants.errors_page_bytes_max]u8 = undefined;
    for (codes.registry) |entry| {
        const page = render_page(entry.code, &buffer);
        try testing.expect(std.mem.startsWith(u8, page, "<!doctype html>\n"));
        try testing.expect(std.mem.indexOf(u8, page, "<h1>ZC-") != null);
        try testing.expect(std.mem.indexOf(u8, page, codes.full_name(entry.code)) != null);
        try testing.expect(std.mem.indexOf(u8, page, "zcube explain ") != null);
        try testing.expect(std.mem.count(u8, page, "<style>") == 1);
        try testing.expect(std.mem.count(u8, page, "<p>") == std.mem.count(u8, page, "</p>") -
            std.mem.count(u8, page, "<p class="));
    }
}

test "text is escaped and paragraphs follow the blank lines" {
    // Goal: the negative space. Markup characters in an explanation cannot become markup, and
    // hard-wrapped lines flow into one paragraph.
    var buffer: [constants.errors_page_bytes_max]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    write_paragraphs(&writer, "a < b & \"c\"\nsecond line\n\nnew > paragraph");
    try testing.expectEqualStrings(
        "<p>a &lt; b &amp; &quot;c&quot; second line</p>\n<p>new &gt; paragraph</p>\n",
        writer.buffered(),
    );
}

test "the index links every code, and pages are deterministic" {
    // Goal: nothing in a page depends on time or order, so --check is meaningful.
    var first: [constants.errors_page_bytes_max]u8 = undefined;
    var second: [constants.errors_page_bytes_max]u8 = undefined;
    const index = render_index(&first);
    for (codes.registry) |entry| {
        var name_buffer: [32]u8 = undefined;
        const tag = @tagName(entry.code);
        const link = try std.fmt.bufPrint(&name_buffer, "href=\"{s}.html\"", .{tag});
        try testing.expect(std.mem.indexOf(u8, index, link) != null);
    }
    try testing.expectEqualStrings(index, render_index(&second));
    const page = render_page(.E0102, &first);
    try testing.expectEqualStrings(page, render_page(.E0102, &second));
    try testing.expect(std.mem.indexOf(u8, page, "can&#39;t") == null); // Plain quote kept.
    try testing.expect(std.mem.indexOf(u8, page, "can't reach zcube-server") != null);
}

test "the pages are where the docs link of a diagnostic points" {
    // Goal: the `docs` line of every ZC- diagnostic is a page that this tool writes. Method: the
    // product's docs base is the site's URL plus errors/, and the file name is the code's tag.
    const base = @import("diag.zig").product.docs_url_base;
    try testing.expectEqualStrings(site_url ++ "errors/", base);
    var name_buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("E0102.html", page_name(&name_buffer, .E0102));
}
