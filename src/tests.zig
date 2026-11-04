//! Test root: pulls every module's tests into one binary (`zig build test`).

test {
    _ = @import("constants.zig");
    _ = @import("text.zig");
    _ = @import("test_util.zig");
    _ = @import("clock.zig");
    _ = @import("diag/codes.zig");
    _ = @import("diag.zig");
    _ = @import("errors_site.zig");
    _ = @import("store.zig");
    _ = @import("store_failures.zig");
    _ = @import("store_memory.zig");
    _ = @import("store_sqlite.zig");
    _ = @import("pq.zig");
    _ = @import("store_postgres.zig");
    _ = @import("runtime.zig");
    _ = @import("records.zig");
    _ = @import("agent_clock.zig");
    _ = @import("agent_config.zig");
    _ = @import("agent_http.zig");
    _ = @import("agent_client.zig");
    _ = @import("agent_remote.zig");
    _ = @import("agent_remote_test.zig");
    _ = @import("sim_cluster_main.zig");
    _ = @import("sim_swarm_main.zig");
    _ = @import("sim_fleet.zig");
    _ = @import("sim_fleet_issue.zig");
    _ = @import("sim_fleet_state.zig");
    _ = @import("sim_fleet_github.zig");
    _ = @import("fake_files.zig");
    _ = @import("fake_runtime.zig");
    _ = @import("fake_runtime_test.zig");
    _ = @import("zigbox_map.zig");
    _ = @import("zigbox_image.zig");
    _ = @import("zigbox_launch.zig");
    _ = @import("zigbox_runtime.zig");
    _ = @import("zigbox_supervisor.zig");
    _ = @import("host_procs.zig");
    _ = @import("testing/fault_proxy.zig");
    _ = @import("testing/history.zig");
    _ = @import("store_mutant.zig");
    _ = @import("store_faults.zig");
    _ = @import("core.zig");
    _ = @import("server_arena.zig");
    _ = @import("server_config.zig");
    _ = @import("server_http.zig");
    _ = @import("server_listen.zig");
    _ = @import("server_static.zig");
    _ = @import("server.zig");
    _ = @import("server_test.zig");
    _ = @import("pull_arena_test.zig");
    _ = @import("bundle.zig");
    _ = @import("bundle_collect.zig");
    _ = @import("bundle_redact.zig");
    _ = @import("bundle_redact_fuzz.zig");
    _ = @import("cli.zig");
    _ = @import("cli_allocations.zig");
    _ = @import("cli_args.zig");
    _ = @import("cli_commands.zig");
    _ = @import("cli_data.zig");
    _ = @import("cli_env.zig");
    _ = @import("cli_get.zig");
    _ = @import("cli_http.zig");
    _ = @import("cli_local.zig");
    _ = @import("cli_report.zig");
    _ = @import("cli_service.zig");
    _ = @import("cli_view.zig");
    _ = @import("cli_golden.zig");
    _ = @import("cli_test.zig");
    _ = @import("tidy.zig");
}

test "the peer handshake's seeded fuzzer is in this root" {
    // Goal: the fuzzer reads ZCUBE_FUZZ_SEED, an environment the WASI core root does not have, so
    // it is native only. Method: import it; the handshake's own tests come with the core.
    _ = @import("peer_fuzz.zig");
}

test "the peer files and the CA's shell are in this root" {
    // Goal: the shell halves of docs/peer.md (key files, CA, agent identity) are tested natively.
    _ = @import("agent_peer.zig");
    _ = @import("peer_files.zig");
    _ = @import("dir_images.zig");
    _ = @import("fetch_backoff.zig");
    _ = @import("peer_stream.zig");
    _ = @import("peer_server.zig");
    _ = @import("fetch_cli.zig");
    _ = @import("fetch_worker.zig");
    _ = @import("server_ca.zig");
}
