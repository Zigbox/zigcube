//! The console's files, as `zcube-server` serves them. They are embedded in the binary by
//! `web_embed.zig` (the `web_files` module the build generates), so there is no directory to
//! deploy and nothing to read at run time. A request names a file exactly or gets nothing: there is
//! no path to join, so there is nothing to traverse.

const std = @import("std");
const assert = std.debug.assert;
const web = @import("web_files");

pub const Asset = struct {
    bytes: []const u8,
    content_type: []const u8,
};

const index_path = "index.html";
const console_prefix = "/console";

/// The file for a request path: `/` and `/console/` are the page, `/console/js/main.js` and
/// `/js/main.js` are the same file (relative URLs in the page resolve under either). Null if the
/// console has no such file.
pub fn find(path: []const u8) ?Asset {
    if (path.len > 0) assert(path[0] == '/');
    var rest = path;
    if (std.mem.eql(u8, rest, console_prefix)) rest = "/";
    if (std.mem.startsWith(u8, rest, console_prefix ++ "/")) rest = rest[console_prefix.len..];
    if (rest.len == 0) return null;
    rest = rest[1..];
    if (rest.len == 0) rest = index_path;
    for (web.files) |file| {
        if (std.mem.eql(u8, file.path, rest)) {
            return .{ .bytes = file.bytes, .content_type = file.content_type };
        }
    }
    return null;
}

const testing = std.testing;

test "the page is served at / and /console/, files under either, and nothing else" {
    // Goal: relative URLs in the page work from both entry points, and a name that is not a file
    // is nothing, including paths that try to climb out. Method: look each up.
    const page = find("/").?;
    try testing.expect(std.mem.startsWith(u8, page.content_type, "text/html"));
    try testing.expect(std.mem.indexOf(u8, page.bytes, "Zigcube console") != null);
    try testing.expectEqual(page.bytes.ptr, find("/console").?.bytes.ptr);
    try testing.expectEqual(page.bytes.ptr, find("/console/").?.bytes.ptr);
    try testing.expectEqual(page.bytes.ptr, find("/console/index.html").?.bytes.ptr);
    const script = find("/js/main.js").?;
    try testing.expectEqual(script.bytes.ptr, find("/console/js/main.js").?.bytes.ptr);
    try testing.expect(std.mem.startsWith(u8, script.content_type, "text/javascript"));
    const module = find("/console/sim/zcube_console.wasm").?;
    try testing.expectEqualStrings("application/wasm", module.content_type);
    try testing.expectEqual(@as(u8, 0), module.bytes[0]); // "\0asm".
    try testing.expect(find("/nothing") == null);
    try testing.expect(find("/../build.zig") == null);
    try testing.expect(find("/console/../src/api.zig") == null);
    try testing.expect(find("/js/") == null);
    try testing.expect(find("/mock/gen-codes.mjs") == null);
}
