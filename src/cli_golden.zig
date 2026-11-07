//! Golden tests for diagnostics (DIAGNOSTICS.md, "Testing"): for every registered `ZC-` code, one
//! case triggers the condition through the real command line and compares the default, verbose and
//! JSON output with the checked-in files in `src/testdata/cli/`. A change to a message is a change
//! to a golden file in the same commit; `ZCUBE_GOLDEN_UPDATE=<absolute path of that directory>`
//! writes the files instead of comparing, and the diff is the review.
//!
//! Two kinds of case. A *raised* case is a condition of the command line itself (a bad flag, a
//! file that isn't a service, a server that isn't there): the command is run for real. A *relayed*
//! case is a diagnostic that the server, its store or the runtime raises; the server is a canned
//! reply (`Env.transport`), and the golden pins how the command line shows it, the same for
//! every code (DIAGNOSTICS.md principle 6). The producers' own conditions are tested where they
//! are raised (the store conformance suite, the API and controller tests).
//!
//! The second test runs every case in every mode and fails if any output shows a stack trace, a
//! source location, an address or a raw Zig error name. The files are named by the code's tag:
//! E0102.txt, E0102.verbose.txt, E0102.json.txt.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const agent_jobs = @import("agent_jobs.zig");
const cli = @import("cli.zig");
const cli_env = @import("cli_env.zig");
const cli_local = @import("cli_local.zig");
const cli_report = @import("cli_report.zig");
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const fencing = @import("fencing.zig");
const fetch_plan = @import("fetch_plan.zig");
const fetch_worker = @import("fetch_worker.zig");
const secure_random = @import("secure_random.zig");
const testpeer = @import("tls_testpeer.zig");
const tls_client = @import("tls_client.zig");
const x509 = @import("x509.zig");
const x509_test = @import("x509_test.zig");
const Ed25519 = std.crypto.sign.Ed25519;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Style = enum { text, verbose, json };

/// A canned reply to one request.
const Canned = struct { status: u16, body: []const u8 };

const Route = *const fn (path: []const u8) ?Canned;

const Script = union(enum) {
    /// No transport: the real connect, to a port nobody listens on.
    closed_port,
    /// Every request is answered with this diagnostic.
    diagnostic: Builder,
    /// Each request is answered by looking at its path.
    router: Route,
};

const Case = struct {
    code: codes.Code,
    /// The arguments after the program name, without the flags of the style.
    args: []const []const u8,
    script: Script,
    flags: Flags = .{},
    /// The command shows something on standard output before it fails (the change, for apply).
    prints: bool = false,
};

// ---- Canned replies ----------------------------------------------------------------------------

const empty_list = Canned{ .status = 200, .body = "{\"revision\":1,\"kvs\":[],\"continue\":null}" };
const status_ok = Canned{
    .status = 200,
    .body = "{\"server\":{\"version\":\"0.0.0\",\"started_at_ms\":1},\"time_ms\":2," ++
        "\"store\":{\"backend\":\"sqlite\",\"ok\":true,\"revision\":1,\"compacted_revision\":0}}",
};
const dry_run_update = Canned{
    .status = 200,
    .body = "{\"request_id\":\"r-0000001\",\"dry_run\":true,\"action\":\"update\"," ++
        "\"name\":\"hello\",\"generation\":1,\"change\":\"replicas 3 \\u2192 5\"}",
};

fn route_empty(path: []const u8) ?Canned {
    if (std.mem.startsWith(u8, path, "/v1/status")) return status_ok;
    return empty_list;
}

fn route_not_json(path: []const u8) ?Canned {
    _ = path;
    return .{ .status = 200, .body = "<html>welcome to nginx</html>" };
}

fn route_dry_run(path: []const u8) ?Canned {
    _ = path;
    return dry_run_update;
}

// ---- Relayed diagnostics -----------------------------------------------------------------------
//
// What the server, its store, the controllers and the runtime say, in the words of their code
// (the file named after each function is where the words come from).

const Builder = *const fn (diag: *diag_mod.Diag) void;

/// A diagnostic of `code` with these causes (the real one last) and one fix.
fn sample(
    diag: *diag_mod.Diag,
    code: codes.Code,
    causes: []const []const u8,
    sentence: []const u8,
) void {
    diag.raise(code);
    for (causes) |cause| diag.cause("{s}", .{cause});
    diag.fix(.{ .sentence = sentence });
}

fn conflict(diag: *diag_mod.Diag) void { // api.zig
    diag.raise(.E0105);
    diag.cause("service hello was changed by someone else during the request", .{});
    const sentence = "look at it as it is now, then apply again";
    diag.fix_with(sentence, "zcube get service {s}", .{"hello"});
}

fn bad_request(diag: *diag_mod.Diag) void { // api.zig
    diag.raise(.E0104);
    diag.while_("reading the request", .{});
    diag.cause("applied_by must be 1 to 64 bytes", .{});
    diag.fix(.{ .sentence = "see docs/api.md for the parameters of each endpoint" });
}

fn bad_config(diag: *diag_mod.Diag) void { // server_config.zig
    const cause = "the store is nosql:x; it must be memory, sqlite:<path> or postgres:<settings>";
    sample(diag, .E0106, &.{cause}, "name a store zcube-server supports");
}

fn cannot_listen(diag: *diag_mod.Diag) void { // server.zig
    const cause = "can't listen on 127.0.0.1:7070: the address is in use by another process";
    sample(diag, .E0107, &.{cause}, "listen on another port");
    diag.fix(.{ .sentence = "or stop the other process", .command = "ss -ltnp | grep 7070" });
}

fn at_limit(diag: *diag_mod.Diag) void { // server.zig
    const sentence = "raise the process's thread limit (ulimit -u) and start it again";
    sample(diag, .E0108, &.{"the server could not start a thread for its work"}, sentence);
}

fn store_down(diag: *diag_mod.Diag) void { // sim_world.zig, pq.zig
    diag.raise(.E0201);
    diag.while_("reading desired state for the request", .{});
    diag.cause("libpq reported: connection to server at \"127.0.0.1\", port 5432 failed: " ++
        "Connection refused", .{});
    diag.cause("the Postgres server at 127.0.0.1 port 5432 did not accept a connection", .{});
    diag.fix(.{ .sentence = "start Postgres, or correct the host and port in the store settings" });
    diag.fix_with("check that it is accepting connections", "pg_isready -h {s} -p {s}", .{
        "127.0.0.1", "5432",
    });
    diag.context("store", "postgres", .{});
}

fn store_failed(diag: *diag_mod.Diag) void { // store_sqlite.zig
    sample(diag, .E0202, &.{
        "SQLite reported: database or disk is full (result code 13)",
        "the disk holding the store file is full",
    }, "fix that condition, then retry; nothing was changed");
    diag.context("path", "/var/lib/zcube/store.db", .{});
}

fn compacted(diag: *diag_mod.Diag) void { // store_failures.zig
    assert(failures.compacted(diag, 10, 380) == error.Compacted);
}

fn no_hash(diag: *diag_mod.Diag) void { // store_failures.zig
    assert(failures.no_hash(diag, 5, 380) == error.NoHash);
}

fn backwards(diag: *diag_mod.Diag) void { // store_failures.zig
    const rollback: failures.Rollback = .{
        .remembered_revision = 412,
        .remembered_hash = @splat(0xa1),
        .now_revision = 398,
        .now_hash = @splat(0xe5),
    };
    assert(failures.went_backwards(diag, rollback) == error.BackendFailed);
}

fn unusable_file(diag: *diag_mod.Diag) void { // store_failures.zig
    const reason = "AccessDenied";
    assert(failures.remembered_unusable(diag, "/var/lib/zcube/remembered", "read", reason) ==
        error.BackendFailed);
}

fn future(diag: *diag_mod.Diag) void { // store_failures.zig
    assert(failures.future_read(diag, 9000, 412) == error.FutureRevision);
}

fn lease_gone(diag: *diag_mod.Diag) void { // store_failures.zig
    assert(failures.lease_not_found(diag, 43) == error.LeaseNotFound);
}

fn too_large(diag: *diag_mod.Diag) void { // store.zig
    const cause = "a value is 300000 bytes; the limit is 262144";
    const sentence = "store large data outside the control plane and keep a reference";
    sample(diag, .E0206, &.{cause}, sentence);
}

fn no_capacity(diag: *diag_mod.Diag) void { // store_failures.zig
    assert(failures.watch_slots_full(diag) == error.NoCapacity);
}

fn store_busy(diag: *diag_mod.Diag) void { // store_sqlite.zig
    sample(diag, .E0208, &.{
        "SQLite reported: database is locked (result code 5)",
        "another connection held the write lock for over 5000 ms",
    }, "stop whatever else uses the store file, then retry");
    diag.context("path", "/var/lib/zcube/store.db", .{});
}

fn store_damaged(diag: *diag_mod.Diag) void { // store_sqlite.zig
    sample(diag, .E0209, &.{
        "SQLite reported: file is not a database (result code 26)",
        "the store file is damaged or is not a zcube store",
    }, "restore the file from a backup, or use another path");
    diag.context("path", "/var/lib/zcube/store.db", .{});
}

fn store_too_new(diag: *diag_mod.Diag) void { // store_sqlite.zig
    const cause = "the store file has schema version 3; this zcube understands up to 2";
    const sentence = "run the zcube version that created the file, or upgrade zcube";
    sample(diag, .E0210, &.{cause}, sentence);
    diag.context("path", "/var/lib/zcube/store.db", .{});
}

fn store_credentials(diag: *diag_mod.Diag) void { // pq.zig
    sample(diag, .E0211, &.{
        "libpq reported: password authentication failed for user \"zcube\"",
        "Postgres at 127.0.0.1 did not let the role zcube in",
    }, "correct the user and password in the store settings");
    diag.context("user", "zcube", .{});
}

fn store_no_database(diag: *diag_mod.Diag) void { // pq.zig
    sample(diag, .E0212, &.{
        "libpq reported: database \"zcube\" does not exist",
        "Postgres at 127.0.0.1 has no database named zcube",
    }, "create the database, or correct its name in the store settings");
    diag.context("db", "zcube", .{});
}

fn store_dropped(diag: *diag_mod.Diag) void { // pq.zig
    sample(diag, .E0213, &.{
        "libpq reported: server closed the connection unexpectedly",
        "the connection to Postgres dropped; nothing was changed",
    }, "retry the command; zcube reconnects before the next operation");
}

fn bad_record(diag: *diag_mod.Diag) void { // records.zig
    const cause = "the value at /services/old is not a valid service record";
    sample(diag, .E0301, &.{cause}, "fix or delete that key; the next pass tries again");
}

fn too_many(diag: *diag_mod.Diag) void { // controller.zig
    const cause = "more than 512 records under /replicas/";
    sample(diag, .E0302, &.{cause}, "delete what is no longer needed");
}

fn record_too_new(diag: *diag_mod.Diag) void { // records.zig
    const cause = "the value at /observed/node1/hello-1 is version 3; this release reads up to " ++
        "version 2";
    sample(diag, .E0303, &.{cause}, "run the zcube release that wrote it, or upgrade this one");
}

fn job_invalid(diag: *diag_mod.Diag) void { // api.zig
    const cause = "deadline_ms is 0; a job needs a deadline between 1 ms and 24 hours";
    sample(diag, .E0130, &.{cause}, "set deadline_ms and submit the job again");
}

fn job_differs(diag: *diag_mod.Diag) void { // api.zig
    const cause = "a job named train-7 exists and differs from this one in: command";
    sample(diag, .E0131, &.{cause}, "use another name, or submit exactly the job that exists");
}

fn job_too_many(diag: *diag_mod.Diag) void { // api.zig
    const cause = "512 jobs have not ended; the cluster accepts at most 512";
    sample(diag, .E0132, &.{cause}, "wait for jobs to end, or cancel some, then submit again");
}

fn job_unknown(diag: *diag_mod.Diag) void { // api.zig
    const cause = "no job named train-7";
    sample(diag, .E0133, &.{cause}, "zcube job list shows the jobs that exist");
}

fn job_late(diag: *diag_mod.Diag) void { // api.zig
    const cause = "submit_by_ms 1761350000000 is 12000 ms before the server's clock";
    sample(diag, .E0134, &.{cause}, "submit again with a new submit-by time");
}

fn job_contradicts(diag: *diag_mod.Diag) void { // job_controller.zig
    const cause = "/job-status/train-7 has ended but /job-runs/train-7 does not exist";
    const fix = "restore the missing record, or delete all the job's keys in one transaction";
    sample(diag, .E0307, &.{cause}, fix);
}

fn job_report_dropped(diag: *diag_mod.Diag) void { // job_controller.zig
    const cause = "node2 reported train-7-job after the job ended as failed (unreachable)";
    sample(diag, .W0307, &.{cause}, "zcube why job train-7 shows both");
}

fn job_waits(diag: *diag_mod.Diag) void { // scheduler.zig
    const cause = "no node has 2000m CPU free; the most free is 500m on node1";
    sample(diag, .W0308, &.{cause}, "lower the job's limits, add a node, or wait for a job to end");
}

fn run_end_unknown(diag: *diag_mod.Diag) void { // agent_jobs.zig
    agent_jobs.raise_run_end_unknown(diag, "train-7-job", "/var/lib/zcube-agent");
}

fn run_start_record(diag: *diag_mod.Diag) void { // agent_jobs.zig
    agent_jobs.raise_start_record(diag, "train-7-job", "/var/lib/zcube-agent");
}

fn job_deadline(diag: *diag_mod.Diag) void { // agent_jobs.zig
    agent_jobs.raise_deadline(diag, "train-7-job", true);
}

fn run_input_digest(diag: *diag_mod.Diag) void { // agent_jobs.zig
    agent_jobs.raise_input(diag, "train-7-job", .mismatch);
}

fn pull_record_lost(diag: *diag_mod.Diag) void { // agent.zig
    const cause = "the pull record could not be written to pull.json: NoSpaceLeft";
    sample(diag, .W0504, &.{cause}, "check the state directory's disk space and permissions");
}

fn swarm_fetch_ended(diag: *diag_mod.Diag) void { // zigbox_supervisor.zig
    const cause = "the fetch was killed at its deadline, ms: 1800000";
    const fix = "if it repeats on every start, check the peers and the network";
    sample(diag, .W0603, &.{cause}, fix);
}

fn job_end_unmapped(diag: *diag_mod.Diag) void { // job_controller.zig
    diag.raise(.B0004);
    diag.cause("train-7-job reported an exit of kind exited with no code and no signal", .{});
    diag.fix(.{ .sentence = "report it with the diagnostic bundle" });
}

fn run_too_large(diag: *diag_mod.Diag) void { // records.zig
    diag.raise(.B0005);
    const cause = "the run train-7-job encodes as 20480 bytes, over the 16384 bytes a run may take";
    diag.cause(cause, .{});
    diag.fix(.{ .sentence = "report it with the diagnostic bundle; the job was not started" });
}

fn unknown_container(diag: *diag_mod.Diag) void { // runtime.zig
    const sentence = "list what the runtime knows, then retry";
    sample(diag, .E0501, &.{"no container by that name"}, sentence);
}

fn runtime_failed(diag: *diag_mod.Diag) void { // runtime.zig
    const cause = "the runtime refused to start the process";
    sample(diag, .E0502, &.{cause}, "check the node's runtime, then retry");
}

fn agent_unreachable(diag: *diag_mod.Diag) void { // agent_http.zig
    sample(
        diag,
        .E0503,
        &.{"no answer from zcube-server at 127.0.0.1:7070: the connection was refused"},
        "start the server, or give the agent the address it listens on",
    );
}

fn agent_refused(diag: *diag_mod.Diag) void { // agent_client.zig
    sample(diag, .E0504, &.{
        "zcube-server answered 400: the request can't be understood (ZC-E0104)",
        "body: is not what this endpoint takes: see docs/api.md",
    }, "look at the server's log for this request, or restart the server");
}

fn agent_config(diag: *diag_mod.Diag) void { // agent_config.zig
    sample(diag, .E0505, &.{"the node has no name"}, "give --node, or .node in the file");
}

fn agent_state_dir(diag: *diag_mod.Diag) void { // fake_runtime.zig
    sample(
        diag,
        .E0506,
        &.{"another agent is using the state directory /var/lib/zcube-agent"},
        "give each agent a state directory of its own",
    );
}

fn agent_supervisor(diag: *diag_mod.Diag) void { // fake_runtime.zig
    sample(
        diag,
        .E0507,
        &.{"the host refused to start a supervisor for hello-1"},
        "free process slots on the node, or restart the agent",
    );
}

fn agent_command(diag: *diag_mod.Diag) void { // fake_supervisor.zig
    sample(
        diag,
        .E0508,
        &.{"the command was not found on this node"},
        "check the command in the service file, then apply it again",
    );
}

fn agent_lost(diag: *diag_mod.Diag) void { // fake_runtime.zig
    sample(
        diag,
        .E0509,
        &.{"the supervisor of hello-1 ended without writing how the command ended"},
        "look for something killing zcube-agent processes on this node",
    );
}

fn agent_tree(diag: *diag_mod.Diag) void { // zigbox_image.zig
    sample(
        diag,
        .E0511,
        &.{"the image at ghcr.io/o/r@sha256:00 unpacks to b3:aa11, not b3:51aa9c03"},
        "pull the reference with zbx, and put the tree digest it prints in the service file",
    );
}

fn agent_no_bus(diag: *diag_mod.Diag) void { // zigbox_supervisor.zig
    sample(
        diag,
        .E0512,
        &.{"the user running the agent has no systemd user bus, which limits need"},
        "enable lingering for the agent's user, or remove the limits from the service file",
    );
}

fn agent_host(diag: *diag_mod.Diag) void { // zcube_agent.zig
    sample(
        diag,
        .E0513,
        &.{"this host can't run rootless containers: cgroup v2 is not mounted"},
        "run zbx doctor as the agent's user and fix what it names, or use --runtime fake",
    );
}

fn agent_too_long(diag: *diag_mod.Diag) void { // zigbox_runtime.zig
    sample(
        diag,
        .E0514,
        &.{"an environment variable value is too long"},
        "shorten it in the service file, then apply it again",
    );
}

fn agent_fetch_outlived(diag: *diag_mod.Diag) void { // zigbox_image.zig
    diag.raise(.E0515);
    diag.cause("a process of the swarm fetch was still alive after SIGKILL to its process " ++
        "group, so the image was not pulled: the store takes one writer at a time", .{});
    diag.fix(.{
        .sentence = "find the process in state D and the disk it waits on; the start is retried",
        .command = "ps -eo pid,stat,wchan:32,args | awk '$2 ~ /D/'",
    });
}

fn agent_lease(diag: *diag_mod.Diag) void { // agent_run.zig
    sample(
        diag,
        .W0501,
        &.{"lease 4 ended; node node1 registered again on lease 5"},
        "if this repeats, check the network between the agent and the server",
    );
}

fn peer_fix(diag: *diag_mod.Diag, code: codes.Code, cause: []const u8) void { // peer.zig
    diag.raise(code);
    diag.cause("{s}", .{cause});
    const sentence = "check that both agents joined this cluster (docs/peer.md)";
    diag.fix(.{ .sentence = sentence, .command = "zcube get nodes" });
}

fn peer_foreign_ca(diag: *diag_mod.Diag) void { // peer.zig
    peer_fix(diag, .E0801, "node2's credential is from another CA");
}

fn peer_expired(diag: *diag_mod.Diag) void { // peer.zig
    diag.raise(.E0802);
    diag.cause("node2's credential has expired", .{});
    const sentence = "check the clocks, then restart the agent so it renews";
    diag.fix(.{ .sentence = sentence, .command = "timedatectl" });
}

fn peer_wrong_node(diag: *diag_mod.Diag) void { // peer.zig
    peer_fix(diag, .E0803, "10.0.0.7:7071 answered with another node's credential");
}

fn peer_handshake(diag: *diag_mod.Diag) void { // peer.zig
    peer_fix(diag, .E0804, "the handshake with node2 did not complete");
}

fn peer_record(diag: *diag_mod.Diag) void { // peer.zig
    peer_fix(diag, .E0805, "a record from node2 failed authentication");
}

fn peer_key_file(diag: *diag_mod.Diag) void { // server_ca.zig
    sample(
        diag,
        .E0806,
        &.{"the CA key file <state>/ca.key is readable by other users (mode 0644)"},
        "set its mode to 0600, or delete it so the server creates a new CA",
    );
}

fn peer_removed(diag: *diag_mod.Diag) void { // agent_api.zig
    sample(
        diag,
        .E0807,
        &.{"node node3 is on the server's list of removed nodes"},
        "remove its name from the revoked file, then restart zcube-server",
    );
}

fn peer_limited(diag: *diag_mod.Diag) void { // peer_serve.zig
    sample(
        diag,
        .E0808,
        &.{"peer address 10.0.0.7 started more handshakes than a window allows"},
        "no action needed; it is tried again by itself",
    );
}

fn x509_refused(diag: *diag_mod.Diag) void { // x509.zig
    x509.raise(diag, error.BadSan, "node2", &.{ .field = .subject_alt_name });
}

fn x509_unsigned(diag: *diag_mod.Diag) void { // x509.zig
    x509.raise(diag, error.BadSignature, "node2", &.{});
}

fn x509_expired(diag: *diag_mod.Diag) void { // x509.zig
    const hour_ms = 3_600_000;
    const not_before_ms = 1_793_836_800_000; // 2026-11-05T00:00:00Z
    x509.raise(diag, error.Expired, "node2", &.{
        .not_before_ms = not_before_ms,
        .not_after_ms = not_before_ms + 24 * hour_ms,
        .now_ms = not_before_ms + 26 * hour_ms,
    });
}

fn x509_wrong_server(diag: *diag_mod.Diag) void { // x509.zig
    x509.raise(diag, error.WrongName, "broker.botpike.com", &.{
        .name_expected = "broker.botpike.com",
        .name_found = "other.botpike.com",
    });
}

fn x509_not_issued(diag: *diag_mod.Diag) void { // x509.zig
    x509.raise(diag, error.TooManyLabels, "broker-1", &.{ .field = .identity });
}

fn x509_wrong_use(diag: *diag_mod.Diag) void { // x509.zig
    x509.raise(diag, error.WrongUse, "node2", &.{
        .kind_expected = .server,
        .kind_found = .workload,
    });
}

/// A client that has sent its ClientHello, for the TLS cases below; the hello is copied to `hello`.
fn tls_started(client: *tls_client.Client, hello: []u8) []u8 {
    return tls_started_with(client, hello, &.{
        .anchor = @splat(1),
        .server_name = "broker.botpike.com",
        .now_ms = 1_700_000_000_000,
        .random = @splat(2),
        .session_id = @splat(3),
        .secret = @splat(4),
    });
}

fn tls_started_with(
    client: *tls_client.Client,
    hello: []u8,
    config: *const tls_client.Config,
) []u8 {
    client.init(config);
    client.start();
    const sent = client.output();
    @memcpy(hello[0..sent.len], sent);
    client.drain();
    return hello[0..sent.len];
}

fn tls_refused(client: *tls_client.Client, input: []const u8, diag: *diag_mod.Diag) void {
    var offset: usize = 0;
    while (offset < input.len) {
        const step = client.receive(input[offset..], diag) catch |err| {
            assert(err == error.Refused);
            return;
        };
        offset += step.consumed;
    }
    unreachable; // The input is a refusal.
}

fn tls_alert(diag: *diag_mod.Diag) void { // tls_client.zig
    var client: tls_client.Client = undefined;
    var hello: [1024]u8 = undefined;
    _ = tls_started(&client, &hello);
    var buffer: [16]u8 = undefined;
    tls_refused(&client, testpeer.plain_alert(&buffer, 40), diag);
}

fn tls_overlong_record(diag: *diag_mod.Diag) void { // tls_client.zig
    var client: tls_client.Client = undefined;
    var hello: [1024]u8 = undefined;
    _ = tls_started(&client, &hello);
    tls_refused(&client, &.{ 22, 3, 3, 0x40, 0x01 }, diag);
}

fn entropy_failed(diag: *diag_mod.Diag) void { // secure_random.zig
    secure_random.raise(diag, error.EntropyUnavailable);
}

fn tls_cut_off(diag: *diag_mod.Diag) void { // tls_client.zig
    var client: tls_client.Client = undefined;
    var hello: [1024]u8 = undefined;
    _ = tls_started(&client, &hello);
    assert(client.end_of_input(diag) == error.Refused);
}

fn tls_retry_request(diag: *diag_mod.Diag) void { // tls_client.zig
    var client: tls_client.Client = undefined;
    var hello: [1024]u8 = undefined;
    const sent = tls_started(&client, &hello);
    const key = Ed25519.KeyPair.generateDeterministic(@splat(5)) catch unreachable; // A seed works.
    var peer = testpeer.Peer.init(.{
        .certificates = &.{},
        .key = key,
        .random = @splat(0),
        .secret = @splat(6),
        .faults = .{ .hello_retry = true },
    });
    var flight: [512]u8 = undefined;
    tls_refused(&client, peer.respond(sent, &flight), diag);
}

fn tls_not_asked(diag: *diag_mod.Diag) void { // tls_client.zig
    var client: tls_client.Client = undefined;
    var hello: [1024]u8 = undefined;
    const key = Ed25519.KeyPair.generateDeterministic(@splat(5)) catch unreachable; // A seed works.
    const sent = tls_started_with(&client, &hello, &.{
        .anchor = @splat(1),
        .server_name = "broker.botpike.com",
        .now_ms = 1_700_000_000_000,
        .random = @splat(2),
        .session_id = @splat(3),
        .secret = @splat(4),
        .client_auth = .{ .required = .{
            .certificates = &.{"workload certificate"},
            .signer = tls_client.key_pair_signer(&key),
        } },
    });
    var peer = testpeer.Peer.init(.{
        .certificates = &.{"server certificate"},
        .key = key,
        .random = @splat(0),
        .secret = @splat(6),
    });
    var flight: [1024]u8 = undefined;
    tls_refused(&client, peer.respond(sent, &flight), diag);
}

fn no_signature(context: *const anyopaque, message: []const u8) ?[64]u8 {
    _ = context;
    _ = message;
    return null;
}

fn tls_signer_failed(diag: *diag_mod.Diag) void { // tls_client.zig
    var client: tls_client.Client = undefined;
    var hello: [1024]u8 = undefined;
    const ca = x509_test.ca_pair() catch unreachable; // A fixed seed.
    const key = Ed25519.KeyPair.generateDeterministic(@splat(5)) catch unreachable; // A seed works.
    var leaf: x509.Der = undefined;
    x509.issue_server(&leaf, ca, &.{
        .dns_name = "broker.botpike.com",
        .subject_key = key.public_key.toBytes(),
        .lifetime = x509_test.window,
    }) catch unreachable; // The request is within the bounds.
    const sent = tls_started_with(&client, &hello, &.{
        .anchor = ca.public_key.toBytes(),
        .server_name = "broker.botpike.com",
        .now_ms = x509_test.now,
        .random = @splat(2),
        .session_id = @splat(3),
        .secret = @splat(4),
        .client_auth = .{ .optional = .{
            .certificates = &.{"workload certificate"},
            .signer = .{ .context = &key, .sign = no_signature },
        } },
    });
    var peer = testpeer.Peer.init(.{
        .certificates = &.{leaf.slice()},
        .key = key,
        .random = @splat(0),
        .secret = @splat(6),
        .client_auth = .{ .anchor = ca.public_key.toBytes(), .now_ms = x509_test.now },
    });
    var flight: [4096]u8 = undefined;
    tls_refused(&client, peer.respond(sent, &flight), diag);
}

fn peer_bad_chunk(diag: *diag_mod.Diag) void { // fetch_plan.zig
    fetch_plan.raise_blame(diag, .{ .peer = 0, .chunk = 4 }, "node2", 24);
}

fn tree_missing(diag: *diag_mod.Diag) void { // fetch_worker.zig
    const tried = "node2, node3 and the registry";
    fetch_worker.raise_tree_missing(diag, "b3:7f1c4e9a5d20", tried);
}

fn peer_bad_tree(diag: *diag_mod.Diag) void { // fetch_worker.zig
    fetch_worker.raise_bad_tree(diag, "node2", "b3:7f1c4e9a5d20");
}

fn bad_lease(diag: *diag_mod.Diag) void { // server_config.zig
    fencing.raise_problem(diag, 4_000, .ttl_too_short);
}

fn tenure_ended(diag: *diag_mod.Diag) void { // agent_api.zig
    const cause = "node node1 was registered again since this agent registered it";
    sample(diag, .E0510, &.{cause}, "nothing: the agent registers again and reports anew");
}

fn repair_unconfirmed(diag: *diag_mod.Diag) void { // api.zig
    diag.raise(.E0401);
    diag.cause(
        "would write 2 assignments, 200 cpu millis and 2048 memory bytes to " ++
            "/allocations/node1, which records 3, 300 and 3072",
        .{},
    );
    diag.fix_with("if that is right, confirm it", "zcube repair allocations {s} --confirm", .{
        "node1",
    });
}

fn repair_no_finding(diag: *diag_mod.Diag) void { // api.zig
    diag.raise(.E0402);
    diag.cause("the allocation auditor has no open finding on node {s}", .{"node1"});
    diag.fix(.{ .sentence = "see every node's accounting", .command = "zcube check allocations" });
}

fn repair_moving(diag: *diag_mod.Diag) void { // api.zig
    diag.raise(.E0403);
    diag.cause("the accounting of {s} kept changing during the request", .{"node1"});
    diag.fix_with("run it again", "zcube repair allocations {s} --confirm", .{"node1"});
}

/// What the auditor embeds in its `allocation_mismatch` decision, relayed as a bug.
fn accounting_bug(diag: *diag_mod.Diag) void { // auditor.zig
    diag.raise(.B0003);
    diag.cause(
        "/allocations/node1 records 3 assignments, 300 cpu millis and 3072 memory bytes; " ++
            "its assignments sum to 2, 200 and 2048",
        .{},
    );
    diag.fix_with("check the accounting, then repair it", "zcube repair allocations {s} " ++
        "--confirm", .{"node1"});
}

/// A check that finds node1's record one assignment ahead of its assignments.
fn route_disagreeing(path: []const u8) ?Canned {
    if (!std.mem.startsWith(u8, path, "/v1/check/allocations")) return null;
    return .{
        .status = 200,
        // Captured from api_test.zig's "check shows it" test (a corrupted node1), verbatim.
        .body = @embedFile("testdata/cli/check_allocations.json"),
    };
}

/// A bug the server reports (it has written its own bundle, on its own machine).
fn server_bug(diag: *diag_mod.Diag) void { // store_postgres.zig
    diag.raise(.B0001);
    diag.cause("the store log has a hole between revisions 41 and 44", .{});
    diag.cause("a watch read the log again 3 times and the revision stayed missing", .{});
}

// ---- The cases ---------------------------------------------------------------------------------

const get_service: []const []const u8 = &.{ "get", "service" };
const hello_file = "src/testdata/cli/hello.zon";
const apply_hello: []const []const u8 = &.{ "apply", hello_file };
const apply_yes: []const []const u8 = &.{ "apply", hello_file, "--yes" };

/// A condition the server's side raises: any request is answered with it.
fn relayed(code: codes.Code, build: Builder) Case {
    return .{ .code = code, .args = get_service, .script = .{ .diagnostic = build } };
}

/// A diagnostic the server sends, answered to the command that would meet it.
fn relayed_to(code: codes.Code, args: []const []const u8, build: Builder) Case {
    return .{ .code = code, .args = args, .script = .{ .diagnostic = build } };
}

const job_run = [_][]const u8{ "job", "run", "x", "--image", "b3:51aa9c03", "--command", "true" };

/// A condition of the command line itself, run for real against a server that is not there.
fn raised(code: codes.Code, args: []const []const u8) Case {
    return .{ .code = code, .args = args, .script = .closed_port };
}

/// A command line against a server that answers by looking at the path.
fn routed(code: codes.Code, args: []const []const u8, route: Route) Case {
    return .{ .code = code, .args = args, .script = .{ .router = route } };
}

const cases = [_]Case{
    routed(.E0101, &.{ "get", "service", "nosuch" }, route_empty),
    raised(.E0102, get_service),
    routed(.E0103, get_service, route_not_json),
    relayed(.E0104, bad_request),
    .{ .code = .E0105, .args = apply_yes, .script = .{ .diagnostic = conflict } },
    relayed(.E0106, bad_config),
    relayed(.E0107, cannot_listen),
    relayed(.E0108, at_limit),
    raised(.E0109, &.{ "apply", "src/testdata/cli/missing.zon" }),
    raised(.E0110, &.{ "apply", "src/testdata/cli/typo.zon" }),
    raised(.E0111, &.{"frobnicate"}),
    raised(.E0112, &.{ "--server", "nonsense", "get", "service" }),
    with_dry_run(.E0113, .{}),
    with_dry_run(.E0114, .{ .stdin_terminal = true, .stdin_text = "n\n" }),
    with_flags(raised(.E0115, &.{"help"}), .{ .stdout_full = true }),
    with_flags(routed(.E0116, bundle_hello, route_empty), .{ .no_state = true }),
    with_flags(routed(.E0117, &.{ "bundle", "--last" }, route_empty), .{ .missing_state = true }),
    raised(.E0118, &.{ "explain", "nope" }),
    with_flags(routed(.W0119, bundle_unredacted, route_empty), .{ .warning = true }),
    with_flags(raised(.E0120, &.{ "explain", "E0102" }), .{ .no_memory = true }),
    relayed(.E0121, bad_lease),
    with_flags(raised(.E0122, &.{ "local", "up" }), .{ .local = .no_executables }),
    with_flags(raised(.E0123, &.{ "local", "up" }), .{ .local = .dying_executables }),
    with_flags(raised(.E0124, &.{ "local", "up" }), .{ .local = .busy }),
    relayed_to(.E0130, &job_run, job_invalid),
    relayed_to(.E0131, &job_run, job_differs),
    relayed_to(.E0132, &job_run, job_too_many),
    relayed_to(.E0133, &.{ "job", "get", "x" }, job_unknown),
    relayed_to(.E0134, &job_run, job_late),
    relayed(.E0201, store_down),
    relayed(.E0202, store_failed),
    relayed(.E0203, compacted),
    relayed(.E0204, future),
    relayed(.E0205, lease_gone),
    relayed(.E0206, too_large),
    relayed(.E0207, no_capacity),
    relayed(.E0208, store_busy),
    relayed(.E0209, store_damaged),
    relayed(.E0210, store_too_new),
    relayed(.E0211, store_credentials),
    relayed(.E0212, store_no_database),
    relayed(.E0213, store_dropped),
    relayed(.E0214, no_hash),
    relayed(.E0215, backwards),
    relayed(.E0216, unusable_file),
    relayed(.E0301, bad_record),
    relayed(.E0302, too_many),
    relayed(.E0303, record_too_new),
    relayed(.E0307, job_contradicts),
    relayed(.W0307, job_report_dropped),
    relayed(.W0308, job_waits),
    .{ .code = .E0401, .args = repair_node1, .script = .{ .diagnostic = repair_unconfirmed } },
    .{ .code = .E0402, .args = repair_confirmed, .script = .{ .diagnostic = repair_no_finding } },
    .{ .code = .E0403, .args = repair_confirmed, .script = .{ .diagnostic = repair_moving } },
    disagreeing(),
    relayed(.E0501, unknown_container),
    relayed(.E0502, runtime_failed),
    relayed(.E0503, agent_unreachable),
    relayed(.E0504, agent_refused),
    relayed(.E0505, agent_config),
    relayed(.E0506, agent_state_dir),
    relayed(.E0507, agent_supervisor),
    relayed(.E0508, agent_command),
    relayed(.E0509, agent_lost),
    relayed(.E0510, tenure_ended),
    relayed(.E0511, agent_tree),
    relayed(.E0512, agent_no_bus),
    relayed(.E0513, agent_host),
    relayed(.E0514, agent_too_long),
    relayed(.E0515, agent_fetch_outlived),
    relayed(.E0521, run_end_unknown),
    relayed(.E0522, run_start_record),
    relayed(.E0523, run_input_digest),
    relayed(.W0501, agent_lease),
    relayed(.W0503, job_deadline),
    relayed(.W0504, pull_record_lost),
    relayed(.E0801, peer_foreign_ca),
    relayed(.E0802, peer_expired),
    relayed(.E0803, peer_wrong_node),
    relayed(.E0804, peer_handshake),
    relayed(.E0805, peer_record),
    relayed(.E0806, peer_key_file),
    relayed(.E0807, peer_removed),
    relayed(.E0808, peer_limited),
    relayed(.E0809, x509_refused),
    relayed(.E0810, x509_unsigned),
    relayed(.E0811, x509_expired),
    relayed(.E0812, x509_wrong_server),
    relayed(.E0813, tls_alert),
    relayed(.E0814, tls_not_asked),
    relayed(.E0815, tls_overlong_record),
    relayed(.E0816, tls_cut_off),
    relayed(.E0817, x509_not_issued),
    relayed(.E0818, tls_retry_request),
    relayed(.E0819, x509_wrong_use),
    relayed(.E0820, tls_signer_failed),
    relayed(.E0821, entropy_failed),
    relayed(.W0601, peer_bad_chunk),
    relayed(.E0601, tree_missing),
    relayed(.W0602, peer_bad_tree),
    relayed(.W0603, swarm_fetch_ended),
    with_flags(routed(.B0002, get_service, route_empty), .{ .silent_failure = true }),
    relayed(.B0003, accounting_bug),
    relayed(.B0004, job_end_unmapped),
    relayed(.B0005, run_too_large),
};

const repair_node1: []const []const u8 = &.{ "repair", "allocations", "node1" };
const repair_confirmed: []const []const u8 = &.{ "repair", "allocations", "node1", "--confirm" };

/// `check allocations` prints its table, then fails with ZC-E0404.
fn disagreeing() Case {
    var case = routed(.E0404, &.{ "check", "allocations" }, route_disagreeing);
    case.prints = true;
    return case;
}

const bundle_hello: []const []const u8 = &.{ "bundle", "service", "hello" };
const bundle_unredacted: []const []const u8 = &.{ "bundle", "service", "hello", "--no-redact" };

/// The flags of a case that change its environment, not its arguments.
const Flags = struct {
    /// The environment has no state directory.
    no_state: bool = false,
    /// The state directory is one that does not exist.
    missing_state: bool = false,
    stdin_terminal: bool = false,
    stdin_text: []const u8 = "",
    /// Standard output fails every write, as `> /dev/full` does.
    stdout_full: bool = false,
    /// Every request for memory is refused.
    no_memory: bool = false,
    /// A command that fails without saying why (a bug in the command).
    silent_failure: bool = false,
    /// The case succeeds with a warning: the exit code is the command's, not the blame's.
    warning: bool = false,
    /// `zcube local up` runs in a directory of its own, with the executables it needs either
    /// missing or dying at once.
    local: enum { off, no_executables, dying_executables, busy } = .off,
};

fn with_flags(base: Case, flags: Flags) Case {
    var case = base;
    case.flags = flags;
    return case;
}

/// An apply of the file that changes `hello`, which the dry run reports and the user answers.
fn with_dry_run(code: codes.Code, flags: Flags) Case {
    var case = with_flags(routed(code, apply_hello, route_dry_run), flags);
    case.prints = true;
    return case;
}

// ---- Running a case ----------------------------------------------------------------------------

/// What a run of the command line produced.
const Output = struct {
    exit: u8,
    stdout: []const u8,
    stderr: []const u8,
};

const Fixture = struct {
    arena: Allocator,
    script: Script,
};

fn http(arena: Allocator, canned: Canned) []const u8 {
    const format = "HTTP/1.1 {d} Reply\r\nContent-Length: {d}\r\n" ++
        "X-Request-Id: r-0000001\r\n\r\n{s}";
    const args = .{ canned.status, canned.body.len, canned.body };
    return std.fmt.allocPrint(arena, format, args) catch unreachable; // The test arena has room.
}

/// The reply a server sends for a diagnostic: the body of docs/api.md, "Errors".
fn diagnostic_reply(arena: Allocator, build: *const fn (*diag_mod.Diag) void) []const u8 {
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    build(&diag);
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &diag);
    var line: [constants.diag_output_bytes_max]u8 = undefined;
    var writer = Writer.fixed(&line);
    // A diagnostic fits its buffer, and the test arena has room.
    zigbox.diagnostic.write_json(&writer, &diagnostic) catch unreachable;
    const format = "{{\"request_id\":\"r-0000001\",\"diagnostics\":[{s}]}}";
    const json = std.mem.trimEnd(u8, writer.buffered(), "\n");
    const body = std.fmt.allocPrint(arena, format, .{json}) catch unreachable; // Same.
    const status: u16 = switch (diagnostic.blame) {
        .user => 400,
        .environment => 503,
        .external => 502,
        .internal => 500,
    };
    // The statuses docs/api.md gives the job conflicts.
    const sent: u16 = switch (diag.code.?) {
        .E0131 => 409,
        .E0132 => 429,
        .E0133 => 404,
        .E0134 => 410,
        else => status,
    };
    return http(arena, .{ .status = sent, .body = body });
}

fn exchange(
    context: *anyopaque,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) ?[]const u8 {
    _ = method;
    _ = body;
    const fixture: *Fixture = @ptrCast(@alignCast(context));
    return switch (fixture.script) {
        .closed_port => null,
        .diagnostic => |build| diagnostic_reply(fixture.arena, build),
        .router => |route| if (route(path)) |canned| http(fixture.arena, canned) else null,
    };
}

fn drain_fails(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    _ = w;
    _ = data;
    _ = splat;
    return error.WriteFailed;
}

fn refuse_alloc(
    context: *anyopaque,
    length: usize,
    alignment: std.mem.Alignment,
    address: usize,
) ?[*]u8 {
    _ = context;
    _ = length;
    _ = alignment;
    _ = address;
    return null;
}

const refusing_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = refuse_alloc,
        .resize = Allocator.noResize,
        .remap = Allocator.noRemap,
        .free = Allocator.noFree,
    },
};

fn silent_executor(
    env: *const cli_env.Env,
    client: *@import("cli_http.zig").Client,
    parsed: *const @import("cli_args.zig").Parsed,
    line: []const u8,
    report: *cli_report.Report,
) cli_report.Error!void {
    _ = env;
    _ = client;
    _ = parsed;
    _ = line;
    _ = report;
    return error.Failed;
}

const Directory = struct {
    tmp: testing.TmpDir,
    /// The state directory of the run, absolute.
    state: []const u8,
};

fn run_case(arena: Allocator, case: *const Case, style: Style, state_root: []const u8) !Output {
    var args: std.ArrayList([]const u8) = .empty;
    // `job run ... --command WORD...` takes the rest of the line: the style's flags go first.
    const flags_first = std.mem.eql(u8, case.args[0], "job");
    if (!flags_first) try args.appendSlice(arena, case.args);
    switch (style) {
        .text => {},
        .verbose => try args.append(arena, "-v"),
        .json => try args.appendSlice(arena, &.{ "--output", "json" }),
    }
    if (flags_first) try args.appendSlice(arena, case.args);
    var environ = std.process.Environ.Map.init(arena);
    try environ.put("USER", "tester");
    if (case.flags.missing_state) {
        try environ.put("XDG_STATE_HOME", "/nonexistent-zcube-golden-state");
    } else if (!case.flags.no_state) {
        try environ.put("XDG_STATE_HOME", state_root);
    }
    const bin_dir = try prepare_local(arena, case, &environ, state_root);
    // Another `zcube local` holds the lock for the whole run, and this one does not wait for it.
    const held = if (case.flags.local == .busy) try hold_local_lock(arena, state_root) else null;
    defer if (held) |file| file.close(testing.io);
    var stdout: Writer.Allocating = .init(arena);
    var stderr: Writer.Allocating = .init(arena);
    var failing: Writer = .{ .vtable = &.{ .drain = drain_fails }, .buffer = &.{} };
    var input = std.Io.Reader.fixed(case.flags.stdin_text);
    var fixture: Fixture = .{ .arena = arena, .script = case.script };
    const env: cli_env.Env = .{
        .io = testing.io,
        .arena = if (case.flags.no_memory) refusing_allocator else arena,
        .environ = &environ,
        .stdout = if (case.flags.stdout_full) &failing else &stdout.writer,
        .stderr = &stderr.writer,
        .stdin = &input,
        .stdin_is_terminal = case.flags.stdin_terminal,
        .stderr_is_terminal = false,
        .version = "0.0.0-test",
        .deterministic_ids = true,
        .fixed_now_ms = 0,
        .bin_dir = bin_dir,
        .local_lock_wait_ms = 0,
        .transport = if (case.script == .closed_port) null else .{
            .context = &fixture,
            .exchange = exchange,
        },
    };
    const exit = if (case.flags.silent_failure)
        cli.run_with(&env, args.items, silent_executor)
    else
        cli.run(&env, args.items);
    return .{ .exit = exit, .stdout = stdout.written(), .stderr = stderr.written() };
}

fn hold_local_lock(arena: Allocator, state_root: []const u8) !std.Io.File {
    const dir = try std.fmt.allocPrint(arena, "{s}/local", .{state_root});
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);
    const file = try std.fmt.allocPrint(arena, "{s}/lock", .{dir});
    return cli_local.lock_file(testing.io, file, 0);
}

/// For a `zcube local` case: names the run's directory and returns where the executables are.
/// Dying executables are shell scripts that exit at once, as a server that cannot start does.
fn prepare_local(
    arena: Allocator,
    case: *const Case,
    environ: *std.process.Environ.Map,
    state_root: []const u8,
) !?[]const u8 {
    if (case.flags.local == .off) return null;
    try environ.put("ZCUBE_LOCAL_DIR", try std.fmt.allocPrint(arena, "{s}/local", .{state_root}));
    const bins = try std.fmt.allocPrint(arena, "{s}/bin", .{state_root});
    if (case.flags.local == .no_executables) return bins;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(testing.io, bins);
    for ([_][]const u8{ "zcube-server", "zcube-agent" }) |name| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ bins, name });
        try cwd.writeFile(testing.io, .{
            .sub_path = path,
            .data = "#!/bin/sh\nexit 1\n",
            .flags = .{ .permissions = .executable_file },
        });
    }
    return bins;
}

/// The state directory of a run: absolute, because the command line wants an absolute one.
fn state_root_of(arena: Allocator, tmp: *const testing.TmpDir) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(testing.io, arena);
    const format = "{s}/.zig-cache/tmp/{s}/state";
    return std.fmt.allocPrint(arena, format, .{ cwd, tmp.sub_path });
}

/// The output with the state directory (which differs per run) replaced by a name.
fn stable(arena: Allocator, text: []const u8, state_root: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, arena, text, state_root, "<state>");
}

const Golden = struct {
    text: []const u8,
    verbose: []const u8,
    json: []const u8,
};

/// Index of a code's goldens, built at compile time: a registered code without its three files
/// does not compile, which is the build check of DIAGNOSTICS.md ("a golden test for every code").
const goldens = blk: {
    var table: [codes.registry.len]Golden = undefined;
    for (codes.registry, 0..) |entry, index| {
        const name = @tagName(entry.code);
        table[index] = .{
            .text = @embedFile("testdata/cli/" ++ name ++ ".txt"),
            .verbose = @embedFile("testdata/cli/" ++ name ++ ".verbose.txt"),
            .json = @embedFile("testdata/cli/" ++ name ++ ".json.txt"),
        };
    }
    break :blk table;
};

fn golden_of(code: codes.Code, style: Style) []const u8 {
    const found = goldens[@backingInt(code)];
    return switch (style) {
        .text => found.text,
        .verbose => found.verbose,
        .json => found.json,
    };
}

/// Where to write goldens instead of comparing, if the environment says so.
fn update_directory() ?[]const u8 {
    return testing.environ.getPosix("ZCUBE_GOLDEN_UPDATE");
}

fn update_golden(directory: []const u8, code: codes.Code, style: Style, text: []const u8) !void {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const suffix = switch (style) {
        .text => "",
        .verbose => ".verbose",
        .json => ".json",
    };
    const format = "{s}/{s}{s}.txt";
    const name = try std.fmt.bufPrint(&path, format, .{ directory, @tagName(code), suffix });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = name, .data = text });
}

test "golden: every code in default, verbose and JSON output" {
    // Goal: the text of each diagnostic is part of the product. Method: run each case through the
    // real command line in each style and compare stderr byte for byte with the checked-in file;
    // the exit code is the blame's (the command's own for a warning), the code is in the output,
    // standard output is empty for a failure, and every JSON line parses.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state_root = try state_root_of(arena, &tmp);
    for (&cases) |*case| {
        for (std.enums.values(Style)) |style| {
            const output = try run_case(arena, case, style, state_root);
            const shown = try stable(arena, output.stderr, state_root);
            if (update_directory()) |directory| {
                try update_golden(directory, case.code, style, shown);
                continue;
            }
            try testing.expectEqualStrings(golden_of(case.code, style), shown);
            try check_case(case, style, output);
        }
    }
}

fn check_case(case: *const Case, style: Style, output: Output) !void {
    const full = codes.full_name(case.code);
    try testing.expect(std.mem.indexOf(u8, output.stderr, full) != null);
    const blame = codes.entry(case.code).blame;
    const expected: u8 = if (case.flags.warning) constants.exit_ok else codes.exit_code(blame);
    try testing.expectEqual(expected, output.exit);
    if (!case.flags.warning and !case.prints) {
        try testing.expectEqual(@as(usize, 0), output.stdout.len);
    }
    if (case.prints and style != .json) try testing.expect(output.stdout.len > 0);
    if (style != .json) return;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output.stderr, "\n"), '\n');
    while (lines.next()) |raw| {
        // With a terminal, the question of apply is the one thing on stderr that is not JSON; it
        // has no newline, so it shares a line with the first diagnostic.
        const line = std.mem.cutPrefix(u8, raw, "apply? [y/N] ") orelse raw;
        var scratch: [2 * constants.diag_output_bytes_max]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        _ = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), line, .{}) catch |err| {
            std.debug.print("{s}: not JSON: {s}\n", .{ full, line });
            return err;
        };
    }
}

test "every registered code has a case, and the panic is the one without a command line" {
    // Goal: the registry cannot gain a code without a golden test. B0001 is the panic handler's
    // (covered below); every other code has a case. The files themselves are checked at compile
    // time by `goldens` above.
    for (codes.registry) |entry| {
        if (entry.code == .B0001) continue;
        const covered = for (cases) |case| {
            if (case.code == entry.code) break true;
        } else false;
        try testing.expect(covered);
    }
    try testing.expectEqual(codes.registry.len - 1, cases.len);
}

/// True if `text` shows what DIAGNOSTICS.md forbids: a trace, a source location, an address or a
/// raw Zig error name. Narrower than Zigbox's detector on purpose: words such as "thread" are
/// ordinary English in a message ("could not start a thread").
fn shows_trace(text: []const u8) bool {
    const markers = [_][]const u8{
        ".zig:", "stack trace", "Stack trace", "panic:", "unreachable code",
    };
    for (markers) |marker| {
        if (std.mem.indexOf(u8, text, marker) != null) return true;
    }
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "error.")) |at| : (from = at + 1) {
        if (at + 6 < text.len and std.ascii.isAlphabetic(text[at + 6])) return true;
    }
    from = 0;
    while (std.mem.indexOfPos(u8, text, from, "0x")) |at| : (from = at + 1) {
        if (at + 2 < text.len and std.ascii.isHex(text[at + 2])) return true;
    }
    return false;
}

test "no raw errors: no output of any case shows a trace or a Zig error name" {
    // Goal: DIAGNOSTICS.md, "No stack traces for users". Method: every case in every style, both
    // streams, then the detector itself on text it must and must not flag.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state_root = try state_root_of(arena, &tmp);
    for (&cases) |*case| {
        for (std.enums.values(Style)) |style| {
            const output = try run_case(arena, case, style, state_root);
            try testing.expect(!shows_trace(try stable(arena, output.stderr, state_root)));
            try testing.expect(!shows_trace(output.stdout));
        }
    }
    try testing.expect(shows_trace("error.AccessDenied"));
    try testing.expect(shows_trace("at src/cli.zig:12:5"));
    try testing.expect(shows_trace("thread 4 panic: index out of bounds"));
    try testing.expect(shows_trace("address 0x7ffd1234"));
    try testing.expect(!shows_trace("the server could not start a thread for its work"));
    try testing.expect(!shows_trace("error[ZC-E0102]: can't reach zcube-server"));
}

test "golden: a panic, in default, verbose and JSON output" {
    // Goal: B0001 as the panic handler writes it. Method: the handler's text for a fixed message
    // in each mode. The default text hides the message; verbose and JSON show it; none shows a
    // trace.
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const message = "index out of bounds: index 5, len 3";
    const styles = [_]Style{ .text, .verbose, .json };
    const modes = [_]cli_report.Mode{ .text, .verbose, .json };
    for (styles, modes) |style, mode| {
        const text = cli_report.panic_text(message, mode, &buffer);
        if (update_directory()) |directory| {
            try update_golden(directory, .B0001, style, text);
            continue;
        }
        try testing.expectEqualStrings(golden_of(.B0001, style), text);
        try testing.expect(!shows_trace(text));
    }
    const hidden = golden_of(.B0001, .text);
    try testing.expect(std.mem.indexOf(u8, hidden, "index out of bounds") == null);
}

test "a bug the server reports gets a bundle on this machine, named in its saved line" {
    // Goal: "an automatic bundle on every bug diagnostic", also when the bug is the server's.
    // Method: a canned bug reply; the output names a bundle under the state directory, the exit
    // code is 70, and the file exists.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state_root = try state_root_of(arena, &tmp);
    const case = relayed(.B0001, server_bug);
    const output = try run_case(arena, &case, .text, state_root);
    try testing.expectEqual(constants.exit_internal, output.exit);
    const saved = try stable(arena, output.stderr, state_root);
    const name = "1970-01-01T00-00-00Z-last.tar.gz";
    try testing.expect(std.mem.indexOf(u8, saved, "<state>/zcube/bundles/" ++ name) != null);
    try tmp.dir.access(testing.io, "state/zcube/bundles/" ++ name, .{});
}
