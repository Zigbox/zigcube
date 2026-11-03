//! The agent's peer identity (docs/peer.md, "Trust model" and "Lifetime, renewal and removal").
//! Shell code: it reads and writes the state directory and calls the server over the agent's
//! transport.
//!
//! Three files in the state directory, all mode 0600: `peer.key` (the node's Ed25519 seed, made on
//! the first run), `peer.cred` (the credential the CA signed, in hex) and `ca.pub` (the CA's public
//! key, in hex). `step` joins when there is no valid pair and renews at half the credential's
//! life, through `POST /v1/agent/nodes/{node}/credential`. A join that fails never stops the
//! agent: replicas run on, and it is tried again after `peer_join_retry_ms`. Time is the node's
//! wall clock, passed in.

const std = @import("std");
const assert = std.debug.assert;
const Ed25519 = std.crypto.sign.Ed25519;
const client_mod = @import("agent_client.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const files = @import("peer_files.zig");
const peer = @import("peer.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const key_file = "peer.key";
pub const credential_file = "peer.cred";
pub const ca_file = "ca.pub";

pub const Error = files.Error;

pub const Peer = struct {
    io: std.Io,
    dir: std.Io.Dir,
    /// The state directory's path, for messages.
    where: []const u8,
    node: []const u8,
    key: Ed25519.KeyPair,
    credential: ?peer.Credential = null,
    ca_public: ?[32]u8 = null,
    /// Wall-clock time at which the credential is renewed; 0 when there is none to keep.
    renew_at_ms: u64 = 0,
    /// A failed join is not tried again before this wall-clock time.
    retry_at_ms: u64 = 0,
    /// The last failure was shown; cleared by a success, so a streak is one report.
    reported: bool = false,
    /// `peer.cred` or `ca.pub` was there and could not be used. They are caches, so `open` went
    /// on without them; the problem is in the `diag` it was given, for the caller to show once.
    stored_problem: bool = false,

    /// Opens the state directory, loads `peer.key` (making it on a first run) and the stored
    /// credential and CA key. `peer.key` that cannot be used is ZC-E0806 and an error. A stored
    /// credential or CA key that cannot be used is a cache that went bad: it is ignored (the
    /// agent joins again), `stored_problem` is set and `diag` holds ZC-E0806 for the caller to
    /// show and reset.
    pub fn open(io: std.Io, state_dir: []const u8, node: []const u8, diag: *Diag) Error!Peer {
        assert(diag.code == null);
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, state_dir) catch |err| {
            const verb = "create the directory for";
            return files.unusable(diag, state_dir, key_file, verb, @errorName(err));
        };
        const dir = cwd.openDir(io, state_dir, .{}) catch |err| {
            const verb = "open the directory of";
            return files.unusable(diag, state_dir, key_file, verb, @errorName(err));
        };
        errdefer dir.close(io);
        var opened: Peer = .{
            .io = io,
            .dir = dir,
            .where = state_dir,
            .node = node,
            .key = try load_or_make_key(io, dir, state_dir, diag),
        };
        opened.load_stored(diag) catch {
            assert(diag.code != null);
            opened.stored_problem = true;
            opened.credential = null;
            opened.ca_public = null;
            opened.renew_at_ms = 0;
        };
        return opened;
    }

    pub fn close(self: *Peer) void {
        std.crypto.secureZero(u8, &self.key.secret_key.bytes);
        self.dir.close(self.io);
    }

    /// The CA key id the server says it has now (every answer carries it). A credential from
    /// another CA is dropped so that `due` is true at once: true means the CA changed.
    pub fn observe_ca(self: *Peer, id: [8]u8) bool {
        const credential = self.credential orelse return false;
        if (std.mem.eql(u8, &credential.ca_key_id, &id)) return false;
        self.credential = null;
        self.ca_public = null;
        self.renew_at_ms = 0;
        self.retry_at_ms = 0;
        return true;
    }

    /// Whether `step` would call the server at wall time `now_ms`.
    pub fn due(self: *const Peer, now_ms: u64) bool {
        return now_ms >= self.renew_at_ms and now_ms >= self.retry_at_ms;
    }

    /// Joins or renews if it is time. On failure `diag` says why and the next try is
    /// `peer_join_retry_ms` away. `timeout_ms` caps the call (the caller keeps it short of the
    /// lease's fence).
    pub fn step(
        self: *Peer,
        transport: client_mod.Transport,
        arena: Allocator,
        lease: u64,
        now_ms: u64,
        timeout_ms: u32,
        diag: *Diag,
    ) Error!void {
        assert(diag.code == null);
        assert(lease != 0);
        if (!self.due(now_ms)) return;
        self.join(transport, arena, lease, now_ms, timeout_ms, diag) catch |err| {
            assert(diag.code != null);
            self.retry_at_ms = now_ms + constants.peer_join_retry_ms;
            return err;
        };
        self.reported = false;
    }

    fn join(
        self: *Peer,
        transport: client_mod.Transport,
        arena: Allocator,
        lease: u64,
        now_ms: u64,
        timeout_ms: u32,
        diag: *Diag,
    ) Error!void {
        const public = self.key.public_key.toBytes();
        var body_buffer: [constants.peer_join_request_bytes_max]u8 = undefined;
        const text = "{{\"node_key\":\"{x}\",\"lease\":{d}}}";
        const body = std.fmt.bufPrint(&body_buffer, text, .{ &public, lease }) catch
            unreachable; // 64 digits and a u64 fit the request bound (a comptime constant).
        var target_buffer: [128]u8 = undefined;
        const target = std.fmt.bufPrint(&target_buffer, "/v1/agent/nodes/{s}/credential", .{
            self.node,
        }) catch unreachable; // A node name is at most 63 bytes.
        const request: client_mod.Request = .{
            .method = "POST",
            .target = target,
            .body = body,
            .timeout_ms = timeout_ms,
        };
        const reply = transport.call(arena, request, diag) catch |err| {
            if (diag.code == null) {
                assert(err == error.OutOfMemory);
                client_mod.raise_bad_reply(diag, "the agent ran out of memory");
            }
            return error.Failed;
        };
        if (reply.status != 200) return self.refused(arena, reply, diag);
        const issued = parse_reply(arena, reply.body) orelse
            return bad(diag, "the credential answer is not what the server sends");
        peer.verify(&issued.credential, issued.ca_public, now_ms, self.node) catch |err| {
            peer.raise(diag, err, "zcube-server");
            return error.Failed;
        };
        if (!std.mem.eql(u8, &issued.credential.node_key, &public)) {
            return bad(diag, "the credential is for another key than the one sent");
        }
        self.credential = issued.credential;
        self.ca_public = issued.ca_public;
        self.renew_at_ms = renew_time(&issued.credential);
        self.store(diag) catch |err| {
            // The pair is in memory and works; not being kept means joining again next start.
            self.renew_at_ms = 0;
            return err;
        };
    }

    fn refused(self: *Peer, arena: Allocator, reply: client_mod.Reply, diag: *Diag) Error {
        const code = client_mod.refusal_code(arena, reply.body) orelse "";
        if (std.mem.endsWith(u8, code, "E0807")) {
            diag.raise(.E0807);
            diag.cause("zcube-server will not issue node {s} a peer credential", .{self.node});
            diag.cause("the name is on the server's list of removed nodes", .{});
            const sentence = "if the node belongs here, take it off the server's revoked file, " ++
                "then restart the server";
            diag.fix(.{ .sentence = sentence });
            return error.Failed;
        }
        _ = client_mod.refused(arena, reply, diag) catch {};
        return error.Failed;
    }

    /// Writes `ca.pub` and then `peer.cred`: the credential's presence means the pair is whole.
    fn store(self: *Peer, diag: *Diag) Error!void {
        var ca_text: [65]u8 = undefined;
        const ca_line = std.fmt.bufPrint(&ca_text, "{x}\n", .{&self.ca_public.?}) catch
            unreachable; // Sized.
        try files.write(self.io, self.dir, self.where, ca_file, ca_line, diag);
        const bytes = peer.encode(&self.credential.?);
        var credential_text: [peer.credential_bytes * 2 + 1]u8 = undefined;
        const line = std.fmt.bufPrint(&credential_text, "{x}\n", .{&bytes}) catch
            unreachable; // Sized.
        try files.write(self.io, self.dir, self.where, credential_file, line, diag);
    }

    /// Reads `peer.cred` and `ca.pub`. A pair that does not belong to this key and node is
    /// not an error: it is ignored, and the agent joins again at once.
    fn load_stored(self: *Peer, diag: *Diag) Error!void {
        var ca_buffer: [128]u8 = undefined;
        var credential_buffer: [512]u8 = undefined;
        const io, const dir, const where = .{ self.io, self.dir, self.where };
        const ca_bytes = try files.read(io, dir, where, ca_file, .anchor, &ca_buffer, diag) orelse
            return;
        const credential_bytes = try files.read(
            io,
            dir,
            where,
            credential_file,
            .plain,
            &credential_buffer,
            diag,
        ) orelse return;
        var ca_public: [32]u8 = undefined;
        const ca_text = std.mem.trim(u8, ca_bytes, " \t\r\n");
        const ca_decoded = std.fmt.hexToBytes(&ca_public, ca_text) catch &[0]u8{};
        if (ca_decoded.len != ca_public.len) {
            return files.unusable(diag, self.where, ca_file, "parse", "it is not 64 hex digits");
        }
        var raw: [peer.credential_bytes]u8 = undefined;
        const text = std.mem.trim(u8, credential_bytes, " \t\r\n");
        const decoded = std.fmt.hexToBytes(&raw, text) catch
            return files.unusable(diag, self.where, credential_file, "parse", "it is not hex");
        if (decoded.len != raw.len) {
            const why = "it is the wrong length";
            return files.unusable(diag, self.where, credential_file, "parse", why);
        }
        const credential = peer.decode(&raw) catch
            return files.unusable(diag, self.where, credential_file, "parse", "not a credential");
        const public = self.key.public_key.toBytes();
        if (!std.mem.eql(u8, credential.name(), self.node)) return;
        if (!std.mem.eql(u8, &credential.node_key, &public)) return;
        if (!std.mem.eql(u8, &credential.ca_key_id, &peer.ca_key_id(ca_public))) return;
        self.credential = credential;
        self.ca_public = ca_public;
        self.renew_at_ms = renew_time(&credential);
    }
};

/// ZC-E0801 for the agent's own credential: the server's CA is not the one that signed it. Said
/// once per change; the agent joins again by itself.
pub fn raise_ca_changed(diag: *Diag, node: []const u8) void {
    assert(diag.code == null);
    diag.raise(.E0801);
    diag.cause("the cluster's CA changed: node {s}'s credential is from another", .{node});
    diag.fix(.{ .sentence = "nothing: the agent joins again by itself, within seconds" });
}

/// Half the credential's life from its start.
pub fn renew_time(credential: *const peer.Credential) u64 {
    assert(credential.not_after_ms > credential.not_before_ms);
    const life_ms = credential.not_after_ms - credential.not_before_ms;
    return credential.not_before_ms + @divFloor(life_ms, 2);
}

const Issued = struct { credential: peer.Credential, ca_public: [32]u8 };

const Answer = struct {
    credential: []const u8,
    ca_public: []const u8,
    not_before_ms: u64 = 0,
    not_after_ms: u64 = 0,
};

fn parse_reply(arena: Allocator, body: []const u8) ?Issued {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const answer = std.json.parseFromSliceLeaky(Answer, arena, body, options) catch return null;
    var raw: [peer.credential_bytes]u8 = undefined;
    const decoded = std.fmt.hexToBytes(&raw, answer.credential) catch return null;
    if (decoded.len != raw.len) return null;
    var ca_public: [32]u8 = undefined;
    const ca_decoded = std.fmt.hexToBytes(&ca_public, answer.ca_public) catch return null;
    if (ca_decoded.len != ca_public.len) return null;
    const credential = peer.decode(&raw) catch return null;
    return .{ .credential = credential, .ca_public = ca_public };
}

fn bad(diag: *Diag, problem: []const u8) Error {
    client_mod.raise_bad_reply(diag, problem);
    return error.Failed;
}

fn load_or_make_key(
    io: std.Io,
    dir: std.Io.Dir,
    where: []const u8,
    diag: *Diag,
) Error!Ed25519.KeyPair {
    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    if (try files.read_seed(io, dir, where, key_file, diag)) |loaded| {
        seed = loaded;
        return Ed25519.KeyPair.generateDeterministic(seed) catch
            return files.unusable(diag, where, key_file, "use", "it is not a usable key seed");
    }
    // A seed that gives the identity element has a chance of about 2^-250; draw another.
    while (true) {
        io.random(&seed);
        const key = Ed25519.KeyPair.generateDeterministic(seed) catch continue;
        try files.write_seed(io, dir, where, key_file, seed, diag);
        return key;
    }
}
