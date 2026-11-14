//! Copied from Zigbox 74df642 (src/release_assets.zig), adapted for Zigcube's executables.
//!
//! The release assets that are not packages: one tarball of Zigcube's executables per
//! architecture, the `SHA256SUMS` over every asset, and a CycloneDX 1.5 software bill of
//! materials. Pure: bytes in, bytes out, and the same inputs give the same bytes (the tarball has
//! fixed times, owners and order, and gzip writes no time). `release_assets_main.zig` does the
//! I/O.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");
const model = @import("package/model.zig");
const archive = @import("package/archive.zig");

pub const Error = error{
    OutOfMemory,
    WriteFailed,
    /// A version, name, toolchain version or licence id has a byte outside `[A-Za-z0-9._+-]`.
    BadName,
    /// An asset is not a plain file name `SHA256SUMS` can carry, or two share a name, or a tar
    /// path is too long, or no architecture or one twice was given.
    BadAsset,
    TooManyAssets,
    FileTooLarge,
    BadTime,
};

pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.WriteFailed => "an output buffer could not grow",
        error.BadName => "a version, toolchain version or licence id has an unusable byte",
        error.BadAsset => "an asset name is not a plain file name, or two assets share one, " ++
            "or an architecture is missing or repeated",
        error.TooManyAssets => "more assets than the bound allows",
        error.FileTooLarge => "a file is larger than the bound allows",
        error.BadTime => "the source date is out of range",
    };
}

pub const Architecture = model.Architecture;

pub const architectures = [_]Architecture{ .x86_64, .aarch64 };

/// The executables of a release, by the name they have in the tarball. In `Build.files` the
/// bytes are in this order. A build host names them `<name>-<arch>` (`package_main --bin`).
pub const executables = [_][]const u8{
    "zcube", "zcube-agent", "zcube-server-sqlite", "zcube-server-postgres",
};

/// The revision of the packages: the one `model.Package` defaults to, which names the rpm files.
pub const package_revision = "1";

/// The executables of one architecture.
pub const Build = struct {
    architecture: Architecture,
    files: [executables.len][]const u8,
};

pub const Inputs = struct {
    version: []const u8,
    /// The architectures this release has, each once, in any order.
    builds: []const Build,
    license: []const u8,
    /// The SPDX identifier of `license`, as written in the SBOM.
    license_id: []const u8,
    /// The Zig version that built the binaries (`zig version`).
    zig_version: []const u8,
    /// Seconds since the epoch for every tar entry and for the SBOM's timestamp.
    source_date_epoch: u64,
};

fn name_ok(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text.len > constants.package_name_bytes_max) return false;
    for (text) |byte| {
        const plain = std.ascii.isAlphanumeric(byte);
        if (!plain and byte != '.' and byte != '_' and byte != '+' and byte != '-') return false;
    }
    return true;
}

fn validate(inputs: *const Inputs) Error!void {
    if (!name_ok(inputs.version)) return error.BadName;
    if (!name_ok(inputs.zig_version)) return error.BadName;
    if (!name_ok(inputs.license_id)) return error.BadName;
    if (inputs.source_date_epoch < constants.package_source_date_epoch) return error.BadTime;
    if (inputs.source_date_epoch > constants.release_source_date_max) return error.BadTime;
    if (inputs.builds.len == 0) return error.BadAsset;
    if (inputs.builds.len > architectures.len) return error.BadAsset;
    for (inputs.builds, 0..) |build, index| {
        for (inputs.builds[0..index]) |earlier| {
            if (earlier.architecture == build.architecture) return error.BadAsset;
        }
        for (build.files) |bytes| {
            if (bytes.len > constants.package_file_bytes_max) return error.FileTooLarge;
        }
    }
    if (inputs.license.len > constants.release_license_bytes_max) return error.FileTooLarge;
}

pub fn tarball_name(
    memory: Allocator,
    version: []const u8,
    architecture: Architecture,
) Error![]u8 {
    return std.fmt.allocPrint(memory, "zigcube-{s}-linux-{s}.tar.gz", .{
        version, architecture.rpm_name(),
    }) catch return error.OutOfMemory;
}

pub fn sbom_name(memory: Allocator, version: []const u8) Error![]u8 {
    return std.fmt.allocPrint(memory, "zigcube-{s}.cdx.json", .{version}) catch
        return error.OutOfMemory;
}

/// The path of a package's deb under the signed tree (`package_main --out`), as the apt writer
/// places it. `name` starts with a letter, which is the pool's directory.
pub fn deb_tree_path(
    memory: Allocator,
    name: []const u8,
    version: []const u8,
    architecture: Architecture,
) Error![]u8 {
    assert(name.len > 0);
    return std.fmt.allocPrint(memory, "apt/pool/main/{c}/{s}/{s}_{s}_{s}.deb", .{
        name[0], name, name, version, architecture.deb_name(),
    }) catch return error.OutOfMemory;
}

/// The path of a package's rpm under the signed tree, in the Zigcube dnf tree.
pub fn rpm_tree_path(
    memory: Allocator,
    name: []const u8,
    version: []const u8,
    architecture: Architecture,
) Error![]u8 {
    const arch = architecture.rpm_name();
    return std.fmt.allocPrint(memory, "rpm/zigcube/{s}/{s}-{s}-{s}.{s}.rpm", .{
        arch, name, version, package_revision, arch,
    }) catch return error.OutOfMemory;
}

/// One ustar entry, always owned by root with the fixed time. A tar that sorts and stamps its
/// entries itself is the whole reproducibility story here.
fn tar_entry(
    writer: *std.Io.Writer,
    path: []const u8,
    mode: u32,
    bytes: []const u8,
    epoch: u64,
    directory: bool,
) Error!void {
    var header = std.tar.Writer.Header.init(if (directory) .directory else .regular);
    // The defaults are octal digits ('0000664'); a short number would leave them in place.
    @memset(&header.mode, '0');
    header.setPath("", path) catch return error.BadAsset;
    header.setMode(mode) catch return error.BadAsset;
    header.setSize(bytes.len) catch return error.FileTooLarge;
    header.setMtime(epoch) catch return error.BadTime;
    @memcpy(header.uname[0..4], "root");
    @memcpy(header.gname[0..4], "root");
    if (directory) assert(bytes.len == 0);
    header.write(writer) catch return error.WriteFailed;
    writer.writeAll(bytes) catch return error.WriteFailed;
    const tail = bytes.len % 512;
    if (tail != 0) writer.splatByteAll(0, 512 - tail) catch return error.WriteFailed;
}

/// `zigcube-<v>-linux-<arch>.tar.gz`: a directory of the same name holding the executables in
/// `executables` order, then `LICENSE`.
pub fn tarball(memory: Allocator, inputs: *const Inputs, index: usize) Error![]u8 {
    try validate(inputs);
    const build = inputs.builds[index];
    const directory = try std.fmt.allocPrint(memory, "zigcube-{s}-linux-{s}", .{
        inputs.version, build.architecture.rpm_name(),
    });
    var out: std.Io.Writer.Allocating = .init(memory);
    const writer = &out.writer;
    const epoch = inputs.source_date_epoch;
    const dir_path = try std.fmt.allocPrint(memory, "{s}/", .{directory});
    try tar_entry(writer, dir_path, 0o755, "", epoch, true);
    for (executables, build.files) |name, bytes| {
        const path = try std.fmt.allocPrint(memory, "{s}/{s}", .{ directory, name });
        try tar_entry(writer, path, 0o755, bytes, epoch, false);
    }
    const license_path = try std.fmt.allocPrint(memory, "{s}/LICENSE", .{directory});
    try tar_entry(writer, license_path, 0o644, inputs.license, epoch, false);
    writer.splatByteAll(0, 1024) catch return error.WriteFailed;
    const tar_bytes = out.toOwnedSlice() catch return error.OutOfMemory;
    return archive.gzip(memory, tar_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.WriteFailed,
    };
}

pub const Asset = struct { name: []const u8, bytes: []const u8 };

fn asset_less(_: void, left: Asset, right: Asset) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

/// The text of `SHA256SUMS`: `<hex>  <name>` per asset in byte order of name, the format
/// `sha256sum -c` reads. `assets` is sorted in place.
pub fn sums(memory: Allocator, assets: []Asset) Error![]u8 {
    if (assets.len > constants.release_assets_max) return error.TooManyAssets;
    std.mem.sort(Asset, assets, {}, asset_less);
    var out: std.Io.Writer.Allocating = .init(memory);
    for (assets, 0..) |asset, index| {
        if (!name_ok(asset.name)) return error.BadAsset;
        if (std.mem.startsWith(u8, asset.name, "SHA256SUMS")) return error.BadAsset;
        if (index > 0) {
            if (std.mem.eql(u8, assets[index - 1].name, asset.name)) return error.BadAsset;
        }
        out.writer.print("{s}  {s}\n", .{ &model.digest_hex(asset.bytes), asset.name }) catch
            return error.WriteFailed;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// A CycloneDX 1.5 BOM of the release: `zigcube` with one file component (and its SHA-256) per
/// executable and architecture, the Zig toolchain as the build tool, and what the executables
/// link. Every interpolated value passed `name_ok`, so none needs JSON escaping.
pub fn sbom(memory: Allocator, inputs: *const Inputs) Error![]u8 {
    try validate(inputs);
    var out: std.Io.Writer.Allocating = .init(memory);
    write_sbom(&out.writer, inputs) catch return error.WriteFailed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn write_sbom(writer: *std.Io.Writer, inputs: *const Inputs) std.Io.Writer.Error!void {
    try sbom_head(writer, inputs);
    const total = inputs.builds.len * executables.len;
    var count: usize = 0;
    for (inputs.builds) |build| {
        for (executables, build.files) |name, bytes| {
            count += 1;
            try writer.print(
                \\    {{
                \\      "type": "file",
                \\      "bom-ref": "{s}-linux-{s}",
                \\      "name": "{s}",
                \\      "version": "{s}",
                \\      "description": "ReleaseSafe executable for linux-{s}",
                \\      "hashes": [ {{ "alg": "SHA-256", "content": "{s}" }} ]
                \\    }}{s}
                \\
            , .{
                name,
                build.architecture.rpm_name(),
                name,
                inputs.version,
                build.architecture.rpm_name(),
                &model.digest_hex(bytes),
                if (count < total) "," else "",
            });
        }
    }
    try writer.writeAll("  ],\n  \"dependencies\": [\n");
    try writer.writeAll("    { \"ref\": \"zigcube\", \"dependsOn\": [] }");
    for (inputs.builds) |build| {
        for (executables) |name| {
            try writer.print(
                ",\n    {{ \"ref\": \"{s}-linux-{s}\", \"dependsOn\": [] }}",
                .{ name, build.architecture.rpm_name() },
            );
        }
    }
    try writer.writeAll("\n  ],\n  \"compositions\": [\n    {\n");
    try writer.writeAll("      \"aggregate\": \"complete\",\n      \"assemblies\": [");
    count = 0;
    for (inputs.builds) |build| {
        for (executables) |name| {
            count += 1;
            try writer.print("\"{s}-linux-{s}\"{s}", .{
                name, build.architecture.rpm_name(), if (count < total) ", " else "",
            });
        }
    }
    try writer.writeAll("],\n      \"dependencies\": [\"zigcube\"]\n    }\n  ]\n}\n");
}

/// The document up to the opening of `components`.
fn sbom_head(writer: *std.Io.Writer, inputs: *const Inputs) std.Io.Writer.Error!void {
    const calendar = model.Calendar.from_epoch(inputs.source_date_epoch);
    try writer.print(
        \\{{
        \\  "bomFormat": "CycloneDX",
        \\  "specVersion": "1.5",
        \\  "version": 1,
        \\  "metadata": {{
        \\    "timestamp": "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        \\    "tools": {{
        \\      "components": [
        \\        {{
        \\          "type": "application",
        \\          "name": "zig",
        \\          "version": "{s}",
        \\          "supplier": {{
        \\            "name": "Zig Software Foundation",
        \\            "url": ["https://ziglang.org"]
        \\          }}
        \\        }}
        \\      ]
        \\    }},
        \\    "component": {{
        \\      "type": "application",
        \\      "bom-ref": "zigcube",
        \\      "name": "zigcube",
        \\      "version": "{s}",
        \\      "description": "Orchestrator for Zigbox workloads",
        \\      "licenses": [ {{ "license": {{ "id": "{s}" }} }} ],
        \\      "purl": "pkg:github/zigbox/zigcube@v{s}",
        \\      "externalReferences": [
        \\        {{ "type": "website", "url": "https://zigbox.org" }},
        \\        {{ "type": "vcs", "url": "https://github.com/Zigbox/zigcube" }}
        \\      ]
        \\    }},
        \\    "properties": [
        \\      {{
        \\        "name": "zigcube:dependencies",
        \\        "value": "{s}"
        \\      }}
        \\    ]
        \\  }},
        \\  "components": [
        \\
    , .{
        calendar.year,
        calendar.month,
        calendar.day,
        calendar.seconds_of_day / 3600,
        calendar.seconds_of_day % 3600 / 60,
        calendar.seconds_of_day % 60,
        inputs.zig_version,
        inputs.version,
        inputs.license_id,
        inputs.version,
        dependencies_text,
    });
}

const dependencies_text = "the zigbox module pinned in build.zig.zon, built in; " ++
    "zcube-server-sqlite links the system SQLite 3 and zcube-server-postgres the system " ++
    "libpq; no other third-party components";

const sample_builds = [_]Build{
    .{ .architecture = .x86_64, .files = .{ "x86 cube", "x86 agent", "x86 sqlite", "x86 pg" } },
    .{ .architecture = .aarch64, .files = .{ "arm cube", "arm agent", "arm sqlite", "arm pg" } },
};

const sample: Inputs = .{
    .version = "1.2.3",
    .builds = &sample_builds,
    .license = "Apache License\n",
    .license_id = "Apache-2.0",
    .zig_version = "0.17.0",
    .source_date_epoch = 1_794_148_734,
};

test "release_assets: tarballs and sbom give the same bytes twice and hold the entries" {
    // Goal: reproducibility (same inputs, same bytes) and layout; gunzip and read the tar back.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    for (sample_builds, 0..) |build, index| {
        const first = try tarball(memory, &sample, index);
        const second = try tarball(memory, &sample, index);
        try std.testing.expectEqualSlices(u8, first, second);
        // gzip header: magic, deflate, no flags, and a zero time (bytes 4..8).
        try std.testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0 }, first[0..8]);
        var input: std.Io.Reader = .fixed(first);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &window);
        var tar_bytes: std.Io.Writer.Allocating = .init(memory);
        _ = try decompress.reader.streamRemaining(&tar_bytes.writer);
        // The first header: mtime (octal, bytes 136..147) is the fixed epoch, the owner is root.
        const head = tar_bytes.written()[0..512];
        const mtime = try std.fmt.parseInt(u64, std.mem.trimEnd(u8, head[136..147], &.{0}), 8);
        try std.testing.expectEqual(sample.source_date_epoch, mtime);
        try std.testing.expectEqualStrings("root", std.mem.sliceTo(head[265..297], 0));
        var reader: std.Io.Reader = .fixed(tar_bytes.written());
        var names_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var iterator: std.tar.Iterator = .init(&reader, .{
            .file_name_buffer = &names_buffer,
            .link_name_buffer = &link_buffer,
        });
        const expected = [_][]const u8{
            "",                       "/zcube",   "/zcube-agent", "/zcube-server-sqlite",
            "/zcube-server-postgres", "/LICENSE",
        };
        const prefix = try std.fmt.allocPrint(memory, "zigcube-1.2.3-linux-{s}", .{
            build.architecture.rpm_name(),
        });
        var seen: usize = 0;
        while (try iterator.next()) |entry| : (seen += 1) {
            const want = try std.fmt.allocPrint(memory, "{s}{s}", .{ prefix, expected[seen] });
            try std.testing.expectEqualStrings(want, std.mem.trimEnd(u8, entry.name, "/"));
        }
        try std.testing.expectEqual(expected.len, seen);
    }
    const one = try sbom(memory, &sample);
    try std.testing.expectEqualSlices(u8, one, try sbom(memory, &sample));
}

test "release_assets: the sbom is valid JSON that says what is in the build" {
    // Goal: the document parses; has the version, purl, licence, every hash and the toolchain;
    // lists one component per executable and architecture; no dependency has dependencies.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const text = try sbom(memory, &sample);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, memory, text, .{});
    const root = parsed.object;
    try std.testing.expectEqualStrings("CycloneDX", root.get("bomFormat").?.string);
    try std.testing.expectEqualStrings("1.5", root.get("specVersion").?.string);
    const main = root.get("metadata").?.object.get("component").?.object;
    const purl = main.get("purl").?.string;
    try std.testing.expectEqualStrings("pkg:github/zigbox/zigcube@v1.2.3", purl);
    try std.testing.expectEqualStrings("1.2.3", main.get("version").?.string);
    const id = main.get("licenses").?.array.items[0].object.get("license").?.object.get("id");
    try std.testing.expectEqualStrings("Apache-2.0", id.?.string);
    const tools = root.get("metadata").?.object.get("tools").?.object.get("components").?;
    const zig = tools.array.items[0].object.get("version").?.string;
    try std.testing.expectEqualStrings("0.17.0", zig);
    const components = root.get("components").?.array.items;
    try std.testing.expectEqual(sample_builds.len * executables.len, components.len);
    for (components, 0..) |component, index| {
        const build = sample_builds[index / executables.len];
        const bytes = build.files[index % executables.len];
        const hash = component.object.get("hashes").?.array.items[0].object;
        try std.testing.expectEqualStrings("SHA-256", hash.get("alg").?.string);
        const want = model.digest_hex(bytes);
        try std.testing.expectEqualStrings(&want, hash.get("content").?.string);
    }
    const dependencies = root.get("dependencies").?.array.items;
    try std.testing.expectEqual(components.len + 1, dependencies.len);
    for (dependencies) |dependency| {
        const depends_on = dependency.object.get("dependsOn").?.array.items;
        try std.testing.expectEqual(@as(usize, 0), depends_on.len);
    }
    const composition = root.get("compositions").?.array.items[0].object;
    const assemblies = composition.get("assemblies").?.array.items;
    try std.testing.expectEqual(components.len, assemblies.len);
    try std.testing.expect(std.mem.indexOf(u8, text, "no other third-party components") != null);
    // One architecture alone is a valid document with its own components only.
    var single = sample;
    single.builds = sample_builds[1..];
    const half = try sbom(memory, &single);
    const half_parsed = try std.json.parseFromSliceLeaky(std.json.Value, memory, half, .{});
    const half_count = half_parsed.object.get("components").?.array.items.len;
    try std.testing.expectEqual(executables.len, half_count);
}

test "release_assets: sums sorts by name, matches sha256sum's format, refuses bad names" {
    // Goal: the text is exactly what `sha256sum -c` reads; negative space of every refusal.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var assets = [_]Asset{
        .{ .name = "b.tar.gz", .bytes = "b" },
        .{ .name = "a.deb", .bytes = "" },
    };
    const empty_digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const text = try sums(memory, &assets);
    const b_digest = "3e23e8160039594a33894f6564e1b1348bbd7a0088d42c4acb73eeaed59c009d";
    const want = empty_digest ++ "  a.deb\n" ++ b_digest ++ "  b.tar.gz\n";
    try std.testing.expectEqualStrings(want, text);
    var spaced = [_]Asset{.{ .name = "a b", .bytes = "" }};
    try std.testing.expectError(error.BadAsset, sums(memory, &spaced));
    var self_reference = [_]Asset{.{ .name = "SHA256SUMS.asc", .bytes = "" }};
    try std.testing.expectError(error.BadAsset, sums(memory, &self_reference));
    var twice = [_]Asset{ .{ .name = "a", .bytes = "" }, .{ .name = "a", .bytes = "x" } };
    try std.testing.expectError(error.BadAsset, sums(memory, &twice));
}

test "release_assets: a bad version, toolchain, licence id, date or architecture set is refused" {
    // Goal: every interpolated value is checked before it reaches the SBOM or a path.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var bad = sample;
    bad.version = "1.2/3";
    try std.testing.expectError(error.BadName, tarball(memory, &bad, 0));
    bad = sample;
    bad.zig_version = "0.17 0";
    try std.testing.expectError(error.BadName, sbom(memory, &bad));
    bad = sample;
    bad.license_id = "";
    try std.testing.expectError(error.BadName, sbom(memory, &bad));
    bad = sample;
    bad.source_date_epoch = constants.release_source_date_max + 1;
    try std.testing.expectError(error.BadTime, sbom(memory, &bad));
    bad.source_date_epoch = constants.package_source_date_epoch - 1;
    try std.testing.expectError(error.BadTime, sbom(memory, &bad));
    bad = sample;
    bad.builds = &.{};
    try std.testing.expectError(error.BadAsset, sbom(memory, &bad));
    bad.builds = &.{ sample_builds[0], sample_builds[0] };
    try std.testing.expectError(error.BadAsset, sbom(memory, &bad));
}

test "release_assets: the package paths are the ones the apt and dnf writers place" {
    // Goal: copying by computed name finds what `package_main` wrote; compare with the writers'
    // own path functions on their sample package.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const deb = @import("package/deb.zig");
    const rpm = @import("package/rpm.zig");
    const apt = @import("package/apt.zig");
    const sample_package = deb.sample;
    try std.testing.expectEqualStrings(package_revision, sample_package.revision);
    const deb_path = try deb_tree_path(memory, "sample", "1.2.3", .x86_64);
    const pool = try apt.pool_path(memory, &sample_package);
    const deb_want = try std.fmt.allocPrint(memory, "apt/{s}", .{pool});
    try std.testing.expectEqualStrings(deb_want, deb_path);
    const rpm_path = try rpm_tree_path(memory, "sample", "1.2.3", .x86_64);
    const file = try rpm.file_name(memory, &sample_package);
    const rpm_want = try std.fmt.allocPrint(memory, "rpm/zigcube/x86_64/{s}", .{file});
    try std.testing.expectEqualStrings(rpm_want, rpm_path);
}
