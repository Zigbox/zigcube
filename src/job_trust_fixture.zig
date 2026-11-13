//! Signed jobs for the tests of B5's admission check and for the WASM smoke: keys from a seed
//! byte, envelopes signed as `zbx sign` signs them (Ed25519 is deterministic, so the same key and
//! statement give the same line), and a policy that trusts a list of keys. Core code: it runs in
//! the WASM module too (`core_smoke.zig`).

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const job_trust = @import("job_trust.zig");

const trust = zigbox.trust;
const Statement = trust.statement.Statement;

pub const Digest = trust.statement.Digest;

/// A tree digest and its image text, `b3:` and 64 hex digits, from one byte.
pub fn tree(byte: u8) Digest {
    return @splat(byte);
}

pub fn image(buffer: *[67]u8, byte: u8) []const u8 {
    const digest = tree(byte);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.bufPrint(buffer, "b3:{s}", .{hex}) catch unreachable; // 67 bytes exactly.
}

/// A `source` pinned to the manifest digest of `byte`.
pub fn source(buffer: *[128]u8, byte: u8) []const u8 {
    const hex = std.fmt.bytesToHex(tree(byte), .lower);
    // The buffer holds the repository and the pinned digest.
    return std.fmt.bufPrint(buffer, "ghcr.io/zigbox/app@sha256:{s}", .{hex}) catch unreachable;
}

/// Everything a test needs, allocated once: the verdict's scratch and a signing buffer.
pub const Fixture = struct {
    scratch: *job_trust.Scratch,
    policy: *trust.policy.Policy,
    out: []u8,
    work: *trust.dsse.Work,

    pub fn init(allocator: std.mem.Allocator) !Fixture {
        const scratch = try allocator.create(job_trust.Scratch);
        errdefer allocator.destroy(scratch);
        const policy = try allocator.create(trust.policy.Policy);
        errdefer allocator.destroy(policy);
        const out = try allocator.alloc(u8, trust.limits.envelope_bytes_max);
        errdefer allocator.free(out);
        const work = try allocator.create(trust.dsse.Work);
        return .{ .scratch = scratch, .policy = policy, .out = out, .work = work };
    }

    pub fn deinit(fixture: *Fixture, allocator: std.mem.Allocator) void {
        allocator.destroy(fixture.work);
        allocator.free(fixture.out);
        allocator.destroy(fixture.policy);
        allocator.destroy(fixture.scratch);
        fixture.* = undefined;
    }

    /// Parses a policy that trusts the keys of `seeds` (named `key-<seed>`) and, when
    /// `require_signature`, asks for a signature.
    pub fn trust_keys(fixture: *Fixture, seeds: []const u8, require_signature: bool) !void {
        assert(seeds.len <= 4);
        var buffer: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writer.writeAll(".{ .version = 1, .keys = .{ ");
        for (seeds) |seed| {
            const text = public_text(seed);
            try writer.print(".{{ .name = \"key-{d}\", .public = \"{s}\" }}, ", .{ seed, &text });
        }
        try writer.print("}}, .require_signature = {} }}", .{require_signature});
        if (trust.policy.parse(writer.buffered(), fixture.policy)) |_| return error.BadPolicy;
    }

    /// The configuration `admit` takes.
    pub fn config(fixture: *Fixture) job_trust.Trust {
        const path = "/etc/zcube/trust.zon";
        return .{ .policy = fixture.policy, .path = path, .scratch = fixture.scratch };
    }

    /// One line of `zbx trust export`: `statement` signed by the key of `seed`, copied into
    /// `allocator`.
    pub fn sign(
        fixture: *Fixture,
        allocator: std.mem.Allocator,
        seed: u8,
        statement: Statement,
    ) ![]const u8 {
        var rendered: [trust.statement.render_bytes_max]u8 = undefined;
        const payload = trust.statement.render(&rendered, &statement);
        const line = try trust.dsse.sign(fixture.work, fixture.out, seed_of(seed), payload);
        return allocator.dupe(u8, line);
    }

    /// A tree-only signature of `tree(tree_byte)`.
    pub fn sign_tree(
        fixture: *Fixture,
        allocator: std.mem.Allocator,
        seed: u8,
        tree_byte: u8,
    ) ![]const u8 {
        return fixture.sign(allocator, seed, Statement.for_tree(tree(tree_byte), 1_700_000_000));
    }

    /// A signature of `tree(tree_byte)` bound to the manifest of `source(manifest_byte)`.
    pub fn sign_manifest(
        fixture: *Fixture,
        allocator: std.mem.Allocator,
        seed: u8,
        tree_byte: u8,
        manifest_byte: u8,
    ) ![]const u8 {
        const statement = Statement.for_manifest(
            tree(tree_byte),
            "ghcr.io/zigbox/app",
            tree(manifest_byte),
            1_700_000_000,
        );
        return fixture.sign(allocator, seed, statement);
    }
};

fn seed_of(seed: u8) [32]u8 {
    return @splat(seed);
}

pub fn public_text(seed: u8) trust.key.PublicText {
    return trust.key.public_text(trust.key.public_of_seed(seed_of(seed)));
}
