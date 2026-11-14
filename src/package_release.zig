//! What `zig build packages` writes: the `zigbox` deb and rpm for each architecture, the apt and
//! dnf trees around them, the files an owner signs, and the check that every placed file agrees
//! with the metadata that names it. Pure: bytes in, bytes out. `package_main.zig` does the I/O.
//! The package writer in `src/package/` knows nothing about `zbx`; this file does.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");
const package = @import("package.zig");
const model = package.model;
const apt = package.apt;
const dnf = package.dnf;
const deb = package.deb;
const rpm = package.rpm;
const openpgp = package.openpgp;

pub const Error = model.Error || openpgp.Error;

pub const architectures = [_]model.Architecture{ .x86_64, .aarch64 };

/// The five packages Zigcube builds. `zigbox` is Zigbox's own, from its `stable` suite.
pub const Kind = enum {
    zigcube,
    server_sqlite,
    server_postgres,
    agent,
    zigbox_dev,

    pub fn name(kind: Kind) []const u8 {
        return switch (kind) {
            .zigcube => "zigcube",
            .server_sqlite => "zigcube-server-sqlite",
            .server_postgres => "zigcube-server-postgres",
            .agent => "zigcube-agent",
            .zigbox_dev => "zigbox-dev",
        };
    }
};

pub const kinds = std.enums.values(Kind);

pub const Inputs = struct {
    version: []const u8,
    /// The oldest `zigbox` package `zigbox-dev` accepts (the Zigbox this Zigcube is pinned to).
    zigbox_version: []const u8,
    /// Each executable, by architecture in `architectures` order.
    zcube: [architectures.len][]const u8,
    agent: [architectures.len][]const u8,
    server_sqlite: [architectures.len][]const u8,
    server_postgres: [architectures.len][]const u8,
    license: []const u8,
    /// The files of `packaging/`: the two units and the three default configurations.
    server_unit: []const u8,
    agent_unit: []const u8,
    server_sqlite_config: []const u8,
    server_postgres_config: []const u8,
    agent_config: []const u8,
};

/// Detached OpenPGP signatures (binary packets) the owner made in the two rounds of signing.
pub const Signatures = struct {
    /// Over each rpm's main header, architecture-major then in `Kind` order (round 1).
    header: [architectures.len * kinds.len]?[]const u8 = @splat(null),
    /// A clearsigned `Release`, a detached armored signature of it, and of each `repomd.xml`
    /// (round 2).
    in_release: ?[]const u8 = null,
    release_gpg: ?[]const u8 = null,
    repomd_asc: [architectures.len]?[]const u8 = @splat(null),
};

pub const Options = struct {
    signatures: Signatures = .{},
    /// Sign everything with the fixed test key instead (CI; the key vouches for nothing).
    test_key: bool = false,
};

pub const apt_release_path = "apt/dists/" ++ apt.suite ++ "/Release";
pub const apt_in_release_path = "apt/dists/" ++ apt.suite ++ "/InRelease";
pub const apt_release_gpg_path = "apt/dists/" ++ apt.suite ++ "/Release.gpg";
pub const test_key_armored_path = "zigbox-test-key.asc";
pub const test_key_binary_path = "zigbox-test-key.gpg";

/// The dnf tree of Zigcube is `rpm/zigcube/<basearch>/`, beside the `zigbox` tree at
/// `rpm/<basearch>/`.
pub const rpm_directory = "zigcube";

const Flavor = enum { deb, rpm };

fn make_file(path: []const u8, mode: u32, bytes: []const u8, config: bool) model.File {
    return .{ .path = path, .mode = mode, .bytes = bytes, .config = config };
}

fn relation(name: []const u8, sense: model.Sense, version: []const u8) model.Relation {
    return .{ .name = name, .sense = sense, .version = version };
}

/// The files of one package: its executable, the licence where each format keeps it, and for the
/// two daemons a unit and a default configuration the administrator edits.
fn describe_files(
    memory: Allocator,
    inputs: *const Inputs,
    kind: Kind,
    index: usize,
    flavor: Flavor,
) Error![]const model.File {
    const name = kind.name();
    var files: std.ArrayList(model.File) = .empty;
    const license_path = switch (flavor) {
        .deb => try std.fmt.allocPrint(memory, "/usr/share/doc/{s}/copyright", .{name}),
        .rpm => try std.fmt.allocPrint(memory, "/usr/share/licenses/{s}/LICENSE", .{name}),
    };
    if (kind != .zigbox_dev) {
        try files.append(memory, make_file(license_path, 0o644, inputs.license, false));
    }
    switch (kind) {
        .zigcube => {
            const bytes = inputs.zcube[index];
            try files.append(memory, make_file("/usr/bin/zcube", 0o755, bytes, false));
        },
        .server_sqlite, .server_postgres => {
            const sqlite = kind == .server_sqlite;
            const binary = if (sqlite)
                inputs.server_sqlite[index]
            else
                inputs.server_postgres[index];
            const config = if (sqlite)
                inputs.server_sqlite_config
            else
                inputs.server_postgres_config;
            try files.append(memory, make_file("/usr/bin/zcube-server", 0o755, binary, false));
            const unit_path = "/usr/lib/systemd/system/zcube-server.service";
            try files.append(memory, make_file(unit_path, 0o644, inputs.server_unit, false));
            try files.append(memory, make_file("/etc/zigcube/server.zon", 0o644, config, true));
        },
        .agent => {
            const binary = inputs.agent[index];
            try files.append(memory, make_file("/usr/bin/zcube-agent", 0o755, binary, false));
            const unit_path = "/usr/lib/systemd/system/zcube-agent.service";
            try files.append(memory, make_file(unit_path, 0o644, inputs.agent_unit, false));
            const config = inputs.agent_config;
            try files.append(memory, make_file("/etc/zigcube/agent.zon", 0o644, config, true));
        },
        .zigbox_dev => {},
    }
    return files.items;
}

const server_names = [_]model.Relation{
    .{ .name = "zigcube-server-sqlite" },
    .{ .name = "zigcube-server-postgres" },
};

/// What each package says about itself and how it relates to the others, for one format.
fn describe_text(kind: Kind, pkg: *model.Package) void {
    const sqlite_text = "The server is the control plane. This flavour keeps its state in " ++
        "SQLite or memory.\nThe unit is installed disabled and nothing starts at install.";
    switch (kind) {
        .zigcube => {
            pkg.summary = "Zigcube command line";
            pkg.description = "zcube, the command line of Zigcube, the orchestrator for Zigbox\n" ++
                "workloads. It is a static binary with no dependencies.";
        },
        .server_sqlite => {
            pkg.summary = "Zigcube server with the SQLite store";
            pkg.description = sqlite_text;
        },
        .server_postgres => {
            pkg.summary = "Zigcube server with the Postgres store";
            pkg.description = "The server is the control plane. This flavour keeps its state in " ++
                "Postgres or memory.\nThe unit is installed disabled and nothing starts at " ++
                "install.";
        },
        .agent => {
            pkg.summary = "Zigcube node agent";
            pkg.description = "The agent runs the replicas the server assigns to this node. The " ++
                "unit is installed\ndisabled; declare the node's capacity in " ++
                "/etc/zigcube/agent.zon first.";
        },
        .zigbox_dev => {
            pkg.summary = "Zigbox and Zigcube for a development machine";
            pkg.description = "Installs zigbox, the Zigcube server with the SQLite store and " ++
                "the Zigcube agent.\nIt holds no files.";
        },
    }
}

fn describe(
    memory: Allocator,
    inputs: *const Inputs,
    kind: Kind,
    index: usize,
    flavor: Flavor,
) Error!*const model.Package {
    const result = try memory.create(model.Package);
    result.* = .{
        .name = kind.name(),
        .version = inputs.version,
        .architecture = architectures[index],
        .summary = "",
        .description = "",
        .license = "Apache-2.0",
        .homepage = "https://zigbox.org",
        .maintainer = constants.package_maintainer,
        .files = try describe_files(memory, inputs, kind, index, flavor),
    };
    describe_text(kind, result);
    try describe_relations(memory, inputs, kind, flavor, result);
    return result;
}

fn describe_relations(
    memory: Allocator,
    inputs: *const Inputs,
    kind: Kind,
    flavor: Flavor,
    result: *model.Package,
) Error!void {
    const exact = if (flavor == .deb)
        inputs.version
    else
        try std.fmt.allocPrint(memory, "{s}-{s}", .{ inputs.version, result.revision });
    const core = relation("zigcube", .eq, exact);
    var depends: std.ArrayList(model.Relation) = .empty;
    switch (kind) {
        .zigcube => {},
        .server_sqlite, .server_postgres => {
            try depends.append(memory, core);
            const sqlite = kind == .server_sqlite;
            const library = switch (flavor) {
                .deb => if (sqlite) "libsqlite3-0" else "libpq5",
                .rpm => if (sqlite) "sqlite-libs" else "libpq",
            };
            try depends.append(memory, relation(library, .any, ""));
            const other = if (sqlite) server_names[1] else server_names[0];
            result.conflicts = try memory.dupe(model.Relation, &.{other});
            result.replaces = result.conflicts;
            result.provides = try memory.dupe(model.Relation, &.{.{ .name = "zigcube-server" }});
        },
        .agent => {
            try depends.append(memory, core);
            const zigbox: []const []const u8 = &.{"zigbox"};
            result.recommends_deb = zigbox;
            result.recommends_rpm = zigbox;
        },
        .zigbox_dev => {
            const zigbox_exact = if (flavor == .deb)
                inputs.zigbox_version
            else
                try std.fmt.allocPrint(memory, "{s}-1", .{inputs.zigbox_version});
            try depends.append(memory, relation("zigbox", .ge, zigbox_exact));
            try depends.append(memory, relation("zigcube-server-sqlite", .eq, exact));
            try depends.append(memory, relation("zigcube-agent", .eq, exact));
        },
    }
    switch (flavor) {
        .deb => result.depends_deb = depends.items,
        .rpm => result.depends_rpm = depends.items,
    }
}

/// The path an rpm's header is written to for signing, and the name its signature has in a
/// signatures directory.
pub fn header_path(memory: Allocator, rpm_file: []const u8) Error![]u8 {
    return std.fmt.allocPrint(memory, "to-sign/{s}.header", .{rpm_file}) catch
        return error.OutOfMemory;
}

pub fn header_signature_name(memory: Allocator, rpm_file: []const u8) Error![]u8 {
    return std.fmt.allocPrint(memory, "{s}.header.sig", .{rpm_file}) catch
        return error.OutOfMemory;
}

pub fn repomd_path(memory: Allocator, index: usize) Error![]u8 {
    return std.fmt.allocPrint(memory, "rpm/" ++ rpm_directory ++ "/{s}/repodata/repomd.xml", .{
        architectures[index].rpm_name(),
    }) catch return error.OutOfMemory;
}

pub fn repomd_signature_name(memory: Allocator, index: usize) Error![]u8 {
    return std.fmt.allocPrint(memory, "repomd.{s}.xml.asc", .{
        architectures[index].rpm_name(),
    }) catch return error.OutOfMemory;
}

pub fn rpm_file_name(
    memory: Allocator,
    inputs: *const Inputs,
    kind: Kind,
    index: usize,
) Error![]u8 {
    return rpm.file_name(memory, try describe(memory, inputs, kind, index, .rpm));
}

fn add(
    memory: Allocator,
    files: *std.ArrayList(model.TreeFile),
    path: []const u8,
    bytes: []const u8,
) Error!void {
    try files.append(memory, .{ .path = path, .bytes = bytes });
    assert(files.items.len <= constants.repo_files_max);
}

fn add_tree(
    memory: Allocator,
    files: *std.ArrayList(model.TreeFile),
    prefix: []const u8,
    tree: []const model.TreeFile,
) Error!void {
    for (tree) |entry| {
        const path = try std.fmt.allocPrint(memory, "{s}{s}", .{ prefix, entry.path });
        try add(memory, files, path, entry.bytes);
    }
}

fn find(files: []const model.TreeFile, path: []const u8) ?[]const u8 {
    for (files) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.bytes;
    }
    return null;
}

/// Every file under the output directory, by path relative to it. Before the signing rounds the
/// rpms are unsigned and the signature files are absent; each round adds what it was given.
pub fn build(memory: Allocator, inputs: *const Inputs, options: Options) Error![]model.TreeFile {
    var files: std.ArrayList(model.TreeFile) = .empty;
    var debs: std.ArrayList(model.Built) = .empty;
    const key = openpgp.test_key();
    for (architectures, 0..) |architecture, index| {
        var rpms: std.ArrayList(model.Built) = .empty;
        for (kinds) |kind| {
            const deb_package = try describe(memory, inputs, kind, index, .deb);
            const rpm_package = try describe(memory, inputs, kind, index, .rpm);
            const header = try rpm.header_bytes(memory, rpm_package);
            const signature = if (options.test_key)
                try openpgp.sign_detached(memory, key, header)
            else
                options.signatures.header[index * kinds.len + @backingInt(kind)];
            const rpm_bytes = try rpm.write(memory, rpm_package, .{
                .header_signature = signature,
            });
            const rpm_file = try rpm.file_name(memory, rpm_package);
            try add(memory, &files, try header_path(memory, rpm_file), header);
            const deb_bytes = try deb.write(memory, deb_package);
            try debs.append(memory, .{ .package = deb_package, .bytes = deb_bytes });
            try rpms.append(memory, .{ .package = rpm_package, .bytes = rpm_bytes });
        }
        const prefix = try std.fmt.allocPrint(
            memory,
            "rpm/" ++ rpm_directory ++ "/{s}/",
            .{architecture.rpm_name()},
        );
        try add_tree(memory, &files, prefix, try dnf.write(memory, architecture, rpms.items));
    }
    try add_tree(memory, &files, "apt/", try apt.write(memory, debs.items));
    try add_signatures(memory, &files, options);
    return files.items;
}

fn add_signatures(
    memory: Allocator,
    files: *std.ArrayList(model.TreeFile),
    options: Options,
) Error!void {
    const release = find(files.items, apt_release_path).?;
    const key = openpgp.test_key();
    if (options.test_key) {
        const detached = try openpgp.sign_detached(memory, key, release);
        try add(memory, files, apt_in_release_path, try openpgp.clearsign(memory, key, release));
        const release_gpg = try openpgp.armor(memory, "PGP SIGNATURE", detached);
        try add(memory, files, apt_release_gpg_path, release_gpg);
        const public = try openpgp.public_key_packets(memory, key);
        try add(memory, files, test_key_binary_path, public);
        const armored = try openpgp.armor(memory, "PGP PUBLIC KEY BLOCK", public);
        try add(memory, files, test_key_armored_path, armored);
    } else {
        if (options.signatures.in_release) |bytes| {
            try add(memory, files, apt_in_release_path, bytes);
        }
        if (options.signatures.release_gpg) |bytes| {
            try add(memory, files, apt_release_gpg_path, bytes);
        }
    }
    for (0..architectures.len) |index| {
        const path = try repomd_path(memory, index);
        const signature_path = try std.fmt.allocPrint(memory, "{s}.asc", .{path});
        if (options.test_key) {
            const detached = try openpgp.sign_detached(memory, key, find(files.items, path).?);
            const armored = try openpgp.armor(memory, "PGP SIGNATURE", detached);
            try add(memory, files, signature_path, armored);
        } else if (options.signatures.repomd_asc[index]) |bytes| {
            try add(memory, files, signature_path, bytes);
        }
    }
}

/// How far along the two rounds of signing a build is, for the commands the tool prints next.
pub const Round = enum { trees, done };

pub fn round_of(files: []const model.TreeFile) Round {
    if (find(files, apt_in_release_path) == null) return .trees;
    if (find(files, apt_release_gpg_path) == null) return .trees;
    for (0..architectures.len) |index| {
        var buffer: [128]u8 = undefined;
        const format = "rpm/" ++ rpm_directory ++ "/{s}/repodata/repomd.xml.asc";
        const path = std.fmt.bufPrint(&buffer, format, .{
            architectures[index].rpm_name(),
        }) catch unreachable; // The name is a fixed short string; the buffer is 128 bytes.
        if (find(files, path) == null) return .trees;
    }
    return .done;
}

pub const sample_inputs: Inputs = .{
    .version = "1.2.3",
    .zigbox_version = "0.5.0",
    .zcube = .{ "zcube x86", "zcube arm" },
    .agent = .{ "agent x86", "agent arm" },
    .server_sqlite = .{ "sqlite server x86", "sqlite server arm" },
    .server_postgres = .{ "postgres server x86", "postgres server arm" },
    .license = "Apache licence\n",
    .server_unit = "[Service]\n",
    .agent_unit = "[Service]\n",
    .server_sqlite_config = ".{}\n",
    .server_postgres_config = ".{}\n",
    .agent_config = ".{}\n",
};

test "build gives the same bytes twice and names the files of both architectures" {
    // Goal: reproducibility and layout of the whole output with the test key.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const first = try build(memory, &sample_inputs, .{ .test_key = true });
    const second = try build(memory, &sample_inputs, .{ .test_key = true });
    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |left, right| {
        try std.testing.expectEqualStrings(left.path, right.path);
        try std.testing.expectEqualSlices(u8, left.bytes, right.bytes);
    }
    const wanted = [_][]const u8{
        "apt/pool/main/z/zigcube/zigcube_1.2.3_amd64.deb",
        "apt/pool/main/z/zigcube-server-sqlite/zigcube-server-sqlite_1.2.3_arm64.deb",
        "apt/pool/main/z/zigcube-server-postgres/zigcube-server-postgres_1.2.3_amd64.deb",
        "apt/pool/main/z/zigcube-agent/zigcube-agent_1.2.3_arm64.deb",
        "apt/pool/main/z/zigbox-dev/zigbox-dev_1.2.3_amd64.deb",
        "rpm/zigcube/x86_64/zigcube-1.2.3-1.x86_64.rpm",
        "rpm/zigcube/aarch64/zigcube-agent-1.2.3-1.aarch64.rpm",
        "rpm/zigcube/aarch64/zigbox-dev-1.2.3-1.aarch64.rpm",
        "to-sign/zigcube-1.2.3-1.aarch64.rpm.header",
        "apt/dists/zigcube/Release",
    };
    for (wanted) |path| try std.testing.expect(find(first, path) != null);
    try std.testing.expectEqual(Round.done, round_of(first));
    const unsigned = try build(memory, &sample_inputs, .{});
    try std.testing.expectEqual(Round.trees, round_of(unsigned));
    try std.testing.expect(find(unsigned, apt_in_release_path) == null);
}
