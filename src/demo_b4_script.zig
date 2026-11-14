//! demo-b4's script (docs/demos/b4.md): relayed jobs under `--runtime zigbox` whose relay speaks
//! TLS with the run's own certificate to a stock upstream that pins the cluster CA.
//!
//!   1. identity: the job reaches the upstream through `ZCUBE_RELAY`; the upstream logs the
//!      client certificate, whose SPIFFE ID and identity extension (image, placement epoch) the
//!      host decodes and checks against the job;
//!   2. keys: the run's key, read from its supervisor's memory by root on the node, is searched
//!      for by the job in its environment and every file of every mount it sees: none is found;
//!   3. fence: the job cannot see, signal, ptrace or read the memory of any process but its own,
//!      nor reach IPv6 or send UDP to the internet or the node;
//!   4. cancel: a cancel ends the upstream's connection within 10 s;
//!   5. relay stopped: when the relay's listener fails mid-run, the job is killed (ZC-E0702).

const std = @import("std");
const assert = std.debug.assert;
const b3 = @import("demo_b3_script.zig");
const constants = @import("constants.zig");
const relay_tls = @import("demo_relay_tls.zig");
const state = @import("demo_b1_state.zig");
const steps = @import("demo_c2_steps.zig");
const x509 = @import("x509.zig");
const x509_identity = @import("x509_identity.zig");

const Demo = steps.Demo;

const job_identity = "identity";
const job_keys = "keys";
const job_fence = "fence";
const job_cancel = "cancelme";
const job_orphan = "orphan";
const job_net = "net";
const jobs = job_identity ++ "," ++ job_keys ++ "," ++ job_fence ++ "," ++ job_net ++ "," ++
    job_cancel ++ "," ++ job_orphan;

/// The bound on a cancel reaching the upstream (B4's acceptance; R7's bound is tighter).
const cancel_bound_ms: u64 = 10 * 1000;
const poll_ms: u64 = 200;

/// Each job's command ends with its own name, so the node's tools find it (`guest.sh`).
/// `identity`: one request through the relay, then exit 0.
const identity_python =
    \\import os, urllib.request as u
    \\u.urlopen(os.environ["ZCUBE_RELAY"] + "/whoami", timeout=15).read()
;

/// `keys`: waits (bounded by its deadline) for the node's root to publish the candidate keys (the
/// upstream serves them), then looks for each (`keys_search_python`) in its environment and every
/// regular file under every mount it sees but /proc, /sys and /dev, and reports the count through
/// the relay.
const keys_python =
    \\import os,time,urllib.request as u
    \\o=os.path
    \\g=lambda p:u.urlopen(os.environ["ZCUBE_RELAY"]+p,timeout=15).read()
    \\g("/whoami")
    \\while not(c:=g("/candidates")):time.sleep(1)
    \\K=[bytes.fromhex(x)for x in c.split()]
    \\
++ keys_search_python ++
    \\s("environ",open("/proc/self/environ","rb").read())
    \\n=0
    \\X=("/proc","/sys","/dev")
    \\for d,D,F in os.walk("/"):
    \\ D[:]=[x for x in D if not o.join(d,x).startswith(X)]
    \\ for f in F:
    \\  p=o.join(d,f)
    \\  try:
    \\   if o.isfile(p)and not o.islink(p)and o.getsize(p)<1<<26:s(p,open(p,"rb").read());n+=1
    \\  except OSError:pass
    \\g("/keys?candidates=%d&files=%d&found=%d&first=%s"%(len(K),n,len(H),u.quote(str(H[:1]))))
;

/// The search of `keys`, given the candidate seeds `K`: `s(name, data)` adds `name` to `H` once
/// per pattern found in `data`. For each seed and its expanded scalar (SHA-512's first half,
/// clamped): the raw bytes; hex in lower or upper case, bare or with `:`, `-` or ` ` between bytes; and
/// base64 in both alphabets at each of the three alignments a 3-byte group allows (a PKCS#8 PEM
/// puts an Ed25519 seed at DER offset 16), keeping only the 42 characters that depend on the
/// key alone, searched in the data with line breaks removed (a PEM wraps at 64) and the
/// URL-safe alphabet mapped to the standard one. Terse: `keys` must fit one
/// command-line argument (`cli_arg_bytes_max`).
const keys_search_python =
    \\import base64 as B,hashlib
    \\P=[];H=[]
    \\for k in K:
    \\ a=bytearray(hashlib.sha512(k).digest()[:32]);a[0]&=248;a[31]=a[31]&63|64
    \\ for v in k,bytes(a):
    \\  P+=[v]
    \\  for h in[v.hex()]+[v.hex(x)for x in":- "]:P+=[h.encode(),h.upper().encode()]
    \\  P+=[B.b64encode(bytes(i)+v)[j:j+42]for i,j in((0,0),(1,2),(2,3))]
    \\T=bytes.maketrans(b"-_",b"+/")
    \\def s(n,d):
    \\ w=d.translate(T,b"\r\n")
    \\ H.extend(n for p in P if p in d or p in w)
    \\
;

/// `fence`: every count must be 0 and every route `failed`. Its control is a child it forks
/// (`kid`): it must count as one of `others`, and the same probes must reach it (`kid_mem`,
/// `kid_ptrace` 1), so a probe that cannot succeed would fail the row instead of passing it. The
/// mem probe opens `/proc/<pid>/mem`, which checks ptrace access; reading offset 0 would fail on
/// any process (unmapped).
const fence_python =
    \\import ctypes, os, time, urllib.request as u
    \\L = ctypes.CDLL(None, use_errno=True)
    \\k = os.fork()
    \\if k == 0: time.sleep(60); os._exit(0)
    \\V = [int(p) for p in os.listdir("/proc") if p.isdigit()]
    \\O = [p for p in V if p != os.getpid()]
    \\N = [p for p in O if p != k]
    \\def rd(p):
    \\ try: return open("/proc/%d/cmdline" % p, "rb").read()
    \\ except OSError: return b""
    \\see = sum(1 for p in N if b"zcube" in rd(p) or b"zbx" in rd(p))
    \\def alive(p):
    \\ try: os.kill(p, 0); return 1
    \\ except ProcessLookupError: return 0
    \\ except OSError: return 1
    \\top = int(open("/proc/sys/kernel/pid_max").read())
    \\out = sum(alive(p) for p in range(1, top) if p not in V)
    \\def mem(p):
    \\ try: open("/proc/%d/mem" % p, "rb").close(); return 1
    \\ except OSError: return 0
    \\tr = lambda p: int(L.ptrace(16, p, 0, 0) == 0)
    \\q = "see=%d&outside=%d&mem=%d&ptrace=%d&others=%d&kid_mem=%d&kid_ptrace=%d" % (
    \\ see, out, sum(map(mem, N)), sum(map(tr, N)), len(O), mem(k), tr(k))
    \\os.kill(k, 9)
    \\u.urlopen(os.environ["ZCUBE_RELAY"] + "/fence?" + q, timeout=15).read()
;

/// `net`: IPv6 to the internet, UDP to the internet and UDP to the node; each must fail.
/// A UDP send that leaves is caught by the node's echo too (`udp from` in the upstream's log).
const net_python =
    \\import os, socket as k, urllib.request as u
    \\e = os.environ
    \\def t(f):
    \\ try: f(); return "REACHED"
    \\ except Exception: return "failed"
    \\def c6():
    \\ s = k.socket(k.AF_INET6); s.settimeout(3); s.connect(("2606:4700:4700::1111", 443))
    \\def ud(h, p):
    \\ s = k.socket(k.AF_INET, k.SOCK_DGRAM); s.settimeout(3); s.sendto(b"x", (h, p))
    \\q = "ipv6=" + t(c6) + "&udp_internet=" + t(lambda: ud("1.1.1.1", 443))
    \\q += "&udp_node=" + t(lambda: ud(e["NODE_ADDR"], 9091))
    \\u.urlopen(e["ZCUBE_RELAY"] + "/net?" + q, timeout=15).read()
;

/// `cancelme`: a request the upstream holds open, then nothing until the cancel.
const cancel_python =
    \\import os, socket, time, urllib.parse as p
    \\a = p.urlsplit(os.environ["ZCUBE_RELAY"])
    \\s = socket.create_connection((a.hostname, a.port))
    \\s.sendall(b"GET /hold HTTP/1.0\r\n\r\n")
    \\s.recv(64)
    \\time.sleep(3600)
;

/// `orphan`: one request, then sleeps until its relay is stopped under it.
const orphan_python =
    \\import os, time, urllib.request as u
    \\u.urlopen(os.environ["ZCUBE_RELAY"] + "/whoami", timeout=15).read()
    \\time.sleep(3600)
;

pub fn run(demo: *Demo) !void {
    try b3.start(demo, jobs);
    try identity_row(demo);
    try keys_row(demo);
    try fence_row(demo);
    try cancel_row(demo);
    try orphan_row(demo);
    try summary(demo);
}

/// `zcube job run NAME --image TREE --relay botpike <extra> --command python -c SOURCE NAME`:
/// the trailing name marks the job's process for the node's tools (`guest.sh`).
fn run_job(demo: *Demo, name: []const u8, extra: []const []const u8, source: []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(demo.arena(), &.{
        "job", "run", name, "--image", demo.v1_tree, "--relay", "botpike", "--deadline", "10m",
    });
    try args.appendSlice(demo.arena(), extra);
    try args.appendSlice(demo.arena(), &.{ "--command", "python", "-c", source, name });
    const started = try demo.host.zcube(args.items);
    try demo.host.check(started.code == 0, "zcube job run {s} --relay botpike", .{name});
}

fn running(demo: *Demo, name: []const u8) !void {
    const want = b3.Want{ .name = name, .state = "running" };
    try demo.wait_hard(want, b3.in_state, "the job to run", b3.job_wait_ms);
}

fn ended(demo: *Demo, name: []const u8) !state.JobView {
    const want = b3.Want{ .name = name, .state = "" };
    try demo.wait_hard(want, b3.has_ended, "the job to end", b3.job_wait_ms);
    _ = try demo.host.zcube(&.{ "job", "get", name });
    return (try state.job_view(demo.host, name)).?;
}

/// The upstream's log, read without printing it (the rows print what they find).
fn upstream_log(demo: *Demo) ![]const u8 {
    const result = try demo.guests.root(0, "upstream-log", 60);
    if (result.status != 0) return demo.host.fail("guest.sh upstream-log failed", .{});
    return demo.arena().dupe(u8, result.output);
}

const Seen = struct { needle: []const u8 };

fn log_has(seen: Seen, demo: *Demo) !bool {
    const log = try upstream_log(demo);
    return std.mem.indexOf(u8, log, seen.needle) != null;
}

/// The log line of the request `GET <path>` by job `name`, or null.
fn request_line(log: []const u8, path: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, path) == null) continue;
        if (!std.mem.endsWith(u8, field(line, "uri=") orelse continue, name)) continue;
        return line;
    }
    return null;
}

/// The value of `key` (`key=value`, space separated) in `line`.
fn field(line: []const u8, key: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, key)) return word[key.len..];
    }
    return null;
}

/// The value of `key` in a query string `a=b&c=d` in `line`.
fn query(line: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, line, '?') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, line, start, ' ') orelse line.len;
    var pairs = std.mem.splitScalar(u8, line[start + 1 .. end], '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equals], key)) return pair[equals + 1 ..];
    }
    return null;
}

inline fn spiffe(comptime name: []const u8) []const u8 {
    return "spiffe://" ++ relay_tls.cluster ++ "/job/" ++ name;
}

// ---- 1. Identity ----

fn identity_row(demo: *Demo) !void {
    const host = demo.host;
    host.section("1. The job's identity, as a stock TLS upstream sees it");
    try run_job(demo, job_identity, &.{}, identity_python);
    const view = try ended(demo, job_identity);
    demo.expect(view.code != null and view.code.? == 0, "the job reached the upstream through " ++
        "ZCUBE_RELAY and exited 0, got {?d}", .{view.code});
    const log = try upstream_log(demo);
    const line = request_line(log, "GET /whoami", spiffe(job_identity)) orelse {
        demo.expect(false, "the upstream logged the job's request with its SPIFFE ID", .{});
        return;
    };
    host.say("  the upstream's log: {s}", .{line[0..@min(line.len, 120)]});
    demo.expect(true, "the upstream saw the client certificate {s}", .{spiffe(job_identity)});
    const hex = field(line, "der=") orelse return host.fail("no der= in the log line", .{});
    const der = try demo.arena().alloc(u8, hex.len / 2);
    _ = std.fmt.hexToBytes(der, hex) catch return host.fail("der= is not hex", .{});
    var detail: x509.Detail = .{};
    const parsed = x509.parse_profile(der, .cluster, &detail) catch
        return host.fail("the job's certificate does not parse ({t})", .{detail.field});
    const identity = parsed.identity.of(der);
    const decoded = x509_identity.decode(identity) catch
        return host.fail("the identity extension does not decode", .{});
    var want_digest: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want_digest, demo.v1_tree["b3:".len..]);
    host.say("  its identity extension: image b3:{x}, placement epoch {d}, {d} label(s)", .{
        &decoded.image_digest, decoded.placement_epoch, decoded.labels_count,
    });
    var labels = decoded.labels(identity);
    while (try labels.next(identity)) |label| {
        host.say("    label {s}={s}", .{ label.key, label.value });
    }
    demo.expect(std.mem.eql(u8, &decoded.image_digest, &want_digest), "the extension names " ++
        "the job's image, {s}", .{demo.v1_tree});
    demo.expect(view.epoch != null and decoded.placement_epoch == view.epoch.?, "the extension " ++
        "names the run's placement epoch, {?d}", .{view.epoch});
    demo.expect(std.mem.eql(u8, parsed.name.of(der), spiffe(job_identity)), "the " ++
        "certificate's URI is {s}", .{spiffe(job_identity)});
}

// ---- 2. Keys ----

fn keys_row(demo: *Demo) !void {
    const host = demo.host;
    host.section("2. The run's key is nowhere the job can look");
    try run_job(demo, job_keys, &.{}, keys_python);
    try demo.wait_hard(Seen{ .needle = "uri=" ++ spiffe(job_keys) }, log_has, "the job's first " ++
        "request through its relay", b3.job_wait_ms);
    // Root on the node reads the run's key out of the job's supervisor; the job gets the
    // candidates through the upstream and searches its whole world for them.
    _ = try demo.guest(0, "key-candidates {s}", .{job_keys});
    const view = try ended(demo, job_keys);
    demo.expect(view.code != null and view.code.? == 0, "the key search ran to its end, got " ++
        "{?d}", .{view.code});
    const log = try upstream_log(demo);
    const line = request_line(log, "GET /keys?", spiffe(job_keys)) orelse {
        demo.expect(false, "the job reported its key search through the relay", .{});
        return;
    };
    const candidates = query(line, "candidates") orelse "0";
    const searched = query(line, "files") orelse "0";
    const found = query(line, "found") orelse "?";
    host.say("  the job searched {s} file(s) and its environment for {s} candidate key(s)", .{
        searched, candidates,
    });
    demo.expect(!std.mem.eql(u8, candidates, "0"), "the job had the run's key to look for", .{});
    demo.expect(!std.mem.eql(u8, searched, "0"), "the job searched the files of its mounts", .{});
    demo.expect(std.mem.eql(u8, found, "0"), "no key bytes in the job's environment or under " ++
        "any of its mounts (found {s}, first {s})", .{ found, query(line, "first") orelse "?" });
}

// ---- 3. Fence ----

const fence_counts = [_][]const u8{ "see", "outside", "ptrace", "mem" };
const fence_routes = [_][]const u8{ "ipv6", "udp_internet", "udp_node" };
/// The control: the same probes against the job's own child must succeed.
const fence_controls = [_][]const u8{ "kid_mem", "kid_ptrace" };

fn fence_row(demo: *Demo) !void {
    const host = demo.host;
    host.section("3. The fence: no other process, no IPv6, no UDP out");
    const addr_text = try demo.guest(0, "node-addr", .{});
    const node_env = try std.fmt.allocPrint(demo.arena(), "NODE_ADDR={s}", .{
        std.mem.trim(u8, addr_text, " \r\n"),
    });
    try run_job(demo, job_fence, &.{}, fence_python);
    try run_job(demo, job_net, &.{ "--env", node_env }, net_python);
    const fence_line = try report(demo, job_fence, "GET /fence?", spiffe(job_fence)) orelse return;
    const others = std.fmt.parseInt(u32, query(fence_line, "others") orelse "", 10) catch 0;
    host.say("  the job tried {d} other visible process(es), its own child among them", .{others});
    demo.expect(others >= 1, "the job saw its own child, so the probes had a process to try " ++
        "(others {d})", .{others});
    for (fence_controls) |name| {
        const value = query(fence_line, name) orelse "?";
        demo.expect(std.mem.eql(u8, value, "1"), "control: the job's {s} reached its own child " ++
            "(got {s})", .{ name["kid_".len..], value });
    }
    for (fence_counts) |name| {
        const value = query(fence_line, name) orelse "?";
        demo.expect(std.mem.eql(u8, value, "0"), "{s}: 0 processes (got {s})", .{
            fence_meaning(name), value,
        });
    }
    const net_line = try report(demo, job_net, "GET /net?", spiffe(job_net)) orelse return;
    for (fence_routes) |name| {
        const value = query(net_line, name) orelse "?";
        demo.expect(std.mem.eql(u8, value, "failed"), "{s} failed (got {s})", .{
            fence_meaning(name), value,
        });
    }
    demo.expect(std.mem.indexOf(u8, try upstream_log(demo), "udp from") == null, "the node's " ++
        "UDP echo heard nothing from the job", .{});
}

/// Waits for job `name` to end with 0 and returns the line it reported through its relay.
fn report(demo: *Demo, name: []const u8, path: []const u8, uri: []const u8) !?[]const u8 {
    const view = try ended(demo, name);
    demo.expect(view.code != null and view.code.? == 0, "job {s} ran to its end, got {?d}", .{
        name, view.code,
    });
    const line = request_line(try upstream_log(demo), path, uri);
    demo.expect(line != null, "job {s} reported through its relay", .{name});
    return line;
}

fn fence_meaning(name: []const u8) []const u8 {
    const meanings = [_][2][]const u8{
        .{ "see", "visible processes of zcube or zbx (the supervisor, the agent)" },
        .{ "outside", "processes outside its own it can signal (kill 0 to every pid)" },
        .{ "ptrace", "other processes it can ptrace" },
        .{ "mem", "other processes whose memory it can read" },
        .{ "ipv6", "a connect to [2606:4700:4700::1111]:443" },
        .{ "udp_internet", "UDP to 1.1.1.1:443" },
        .{ "udp_node", "UDP to the node's address" },
    };
    for (meanings) |meaning| {
        if (std.mem.eql(u8, meaning[0], name)) return meaning[1];
    }
    unreachable; // Every name above has a meaning.
}

// ---- 4. Cancel ----

fn cancel_row(demo: *Demo) !void {
    const host = demo.host;
    host.section("4. A cancel ends the upstream's connection");
    try run_job(demo, job_cancel, &.{}, cancel_python);
    const open = Seen{ .needle = "hold-open uri=" ++ spiffe(job_cancel) };
    try demo.wait_hard(open, log_has, "the upstream to hold the job's connection", b3.job_wait_ms);
    const closed = "hold-closed uri=" ++ spiffe(job_cancel);
    demo.expect(!try log_has(.{ .needle = closed }, demo), "the connection is open before " ++
        "the cancel", .{});
    const started = host.now_ms();
    _ = try host.zcube(&.{ "job", "cancel", job_cancel });
    var waited_ms: u64 = 0;
    while (!try log_has(.{ .needle = closed }, demo)) {
        waited_ms = host.now_ms() - started;
        if (waited_ms > cancel_bound_ms * 3) break;
        try host.io.sleep(.fromMilliseconds(poll_ms), .awake);
    }
    waited_ms = host.now_ms() - started;
    demo.expect(waited_ms < cancel_bound_ms, "the upstream saw the connection close {d} ms " ++
        "after `zcube job cancel` (bound {d} ms; the time includes the polling)", .{
        waited_ms, cancel_bound_ms,
    });
    const view = try ended(demo, job_cancel);
    demo.expect(view.end_kind != null, "the job ended after its cancel ({s})", .{
        view.end_kind orelse "?",
    });
}

// ---- 5. The relay stops mid-run ----

fn orphan_row(demo: *Demo) !void {
    const host = demo.host;
    host.section("5. The relay stops mid-run: the job is killed");
    try run_job(demo, job_orphan, &.{}, orphan_python);
    try running(demo, job_orphan);
    const seen = Seen{ .needle = "uri=" ++ spiffe(job_orphan) };
    try demo.wait_hard(seen, log_has, "the job's request through its relay", b3.job_wait_ms);
    // The fault: root on the node takes a copy of the relay's listening socket from the job's
    // supervisor (pidfd_getfd) and shuts it down, so the relay's accept fails.
    _ = try demo.guest(0, "stop-relay {s}", .{job_orphan});
    const view = try ended(demo, job_orphan);
    demo.expect(view.end_kind != null and std.mem.eql(u8, view.end_kind.?, "exited") and
        view.code == null, "the job was killed by a signal, not left to sleep (end {s}, code " ++
        "{?d})", .{ view.end_kind orelse "?", view.code });
    const logs = try demo.guest(0, "relay-logs", .{});
    demo.expect(std.mem.indexOf(u8, logs, "ZC-E0702") != null and
        std.mem.indexOf(u8, logs, "the job's command was killed") != null, "the relay's log " ++
        "says why: ZC-E0702, the relay's listener stopped and the command was killed", .{});
}

fn summary(demo: *Demo) !void {
    const host = demo.host;
    host.section("6. Summary");
    _ = try host.zcube(&.{ "job", "list" });
    try host.check(demo.misses == 0, "every rule of the demo held ({d} missed)", .{demo.misses});
}

test "each job's script fits one command-line argument" {
    for ([_][]const u8{
        identity_python, keys_python, fence_python, net_python, cancel_python, orphan_python,
    }) |source| {
        try std.testing.expect(source.len <= constants.cli_arg_bytes_max);
    }
}

/// Drives `keys_search_python` over encodings of a test seed; exits 0 only if each is found and
/// a file without the key is not.
const keys_search_check_python =
    \\import base64
    \\k = bytes(range(1, 33))
    \\K = [k]
    \\
++ keys_search_python ++
    \\der = bytes.fromhex("302e020100300506032b657004220420") + k
    \\pem = b"-----BEGIN PRIVATE KEY-----\n" + base64.b64encode(der) + b"\n-----END PRIVATE KEY-----\n"
    \\assert base64.b64encode(k)[:42] not in pem, "the seed sits off the 3-byte grid in a PEM"
    \\a = bytearray(hashlib.sha512(k).digest()[:32]); a[0] &= 248; a[31] = a[31] & 63 | 64
    \\b64 = base64.b64encode(b"x" * 99 + k + b"y" * 7)
    \\cases = {
    \\ "pkcs8 pem": pem,
    \\ "raw": b"..." + k + b"...",
    \\ "hex upper": b"key=" + k.hex().upper().encode(),
    \\ "hex colons": k.hex(":").encode(),
    \\ "hex spaces upper": k.hex(" ").upper().encode(),
    \\ "hex dashes": k.hex("-").encode(),
    \\ "url-safe, offset 2": base64.urlsafe_b64encode(b"zz" + k),
    \\ "wrapped at 64": b"\n".join(b64[i:i + 64] for i in range(0, len(b64), 64)),
    \\ "scalar raw": bytes(a),
    \\ "scalar hex": bytes(a).hex().encode(),
    \\ "scalar base64, offset 1": base64.b64encode(b"q" + bytes(a)),
    \\}
    \\for name, data in cases.items():
    \\ s(name, data)
    \\ assert name in H, "not found: " + name
    \\H.clear()
    \\s("clean", base64.b64encode(hashlib.sha512(b"clean").digest() * 4) + bytes(range(40, 256)))
    \\assert not H, "found in a file without the key: %r" % H
    \\print("ok")
;

test "the key search finds a seed in a PKCS#8 PEM and its other encodings" {
    // Goal: `keys` cannot miss a leaked seed because of how it was encoded (review of B4 slice
    // 4: base64 was matched only at offsets that are a multiple of 3, and a PKCS#8 Ed25519 PEM
    // puts the seed at DER offset 16). Method: run the job's own search code in python3 over a
    // real PKCS#8 PEM of a test seed and the other encodings, and over a file without it.
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "python3", "-c", keys_search_check_python },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (!result.term.success()) std.debug.print("{s}\n", .{result.stderr});
    try std.testing.expect(result.term.success());
    try std.testing.expectEqualStrings("ok\n", result.stdout);
}
