//! Every named limit in Zigcube, in one place (docs/STYLE.md: put a limit on everything). The
//! `comptime` block at the end states the relationships the code relies on.

const std = @import("std");
const assert = std.debug.assert;

// ---- Exit codes (DIAGNOSTICS.md) -----------------------------------------------------------

pub const exit_ok: u8 = 0;
pub const exit_user: u8 = 1;
pub const exit_environment: u8 = 2;
pub const exit_external: u8 = 3;
/// EX_SOFTWARE: an internal bug.
pub const exit_internal: u8 = 70;

// ---- Diagnostics: the bounds of the collector (same values as Zigbox's) --------------------

pub const diag_causes_count_max: u32 = 6;
pub const diag_whiles_count_max: u32 = 6;
pub const diag_context_count_max: u32 = 6;
pub const diag_fixes_count_max: u32 = 3;
pub const diag_field_bytes_max: u32 = 200;
pub const diag_command_bytes_max: u32 = 160;
/// The longest context key; also the width of the label column of the rendering.
pub const diag_key_bytes_max: u32 = 6;
pub const diag_summary_bytes_max: u32 = 70;
pub const diag_explanation_bytes_max: u32 = 2048;
pub const diag_explanation_line_bytes_max: u32 = 76;
pub const diag_wrap_columns: u32 = 80;
/// "ZC-" and a letter with four digits; Zigbox's "ZBX-E0501" is the longest code on the wire.
pub const diag_code_bytes_max: u32 = 9;
pub const state_path_bytes_max: u32 = 4096;
/// The buffer one rendered diagnostic or `explain` text needs: Zigbox's `output_bytes_max`, which
/// its renderer asserts and proves a maximal diagnostic fits.
pub const diag_output_bytes_max: u32 = 16 * 1024;

// ---- Store ---------------------------------------------------------------------------------

/// Keys are `/`-separated paths (docs/keys.md): printable ASCII, no NUL.
pub const store_key_bytes_max: u32 = 512;
pub const store_value_bytes_max: u32 = 256 * 1024;
/// "Small transactions only" (HANDOFF.md).
pub const store_txn_compares_max: u32 = 16;
pub const store_txn_ops_max: u32 = 16;
/// Most entries one `list` call returns, whatever the caller asks for.
pub const store_list_limit_max: u32 = 500;
/// A page also ends once its values total this many bytes, so one call cannot exhaust an arena.
pub const store_page_bytes_max: u32 = 4 * 1024 * 1024;
/// The most events one `Watch.next` call returns.
pub const store_watch_batch_max: u32 = 256;
/// Open watches per store; a backend provisions this many slots at startup.
pub const store_watches_max: u32 = 256;
pub const store_leases_max: u32 = 4096;
/// Keys one lease may hold. A revoke deletes them all in one revision, and a watch batch never
/// splits a revision, so this must fit in a batch.
pub const store_lease_keys_max: u32 = 64;
pub const lease_ttl_ms_min: u32 = 100;
pub const lease_ttl_ms_max: u32 = 60 * 60 * 1000;
/// How long a SQLite connection waits for another one's write lock before the operation fails
/// with ZC-E0208. A write holds the lock for milliseconds, so this is a stuck-peer limit.
pub const store_sqlite_busy_ms: u32 = 5000;
/// How often a SQLite watch re-reads the log while it waits for events (it has no NOTIFY).
pub const store_watch_poll_ms: u32 = 10;
/// Postgres: connections one store opens for operations. An operation holds one for its whole
/// transaction, so this bounds the operations in flight; a further one waits for a free one.
pub const store_postgres_connections_max: u32 = 8;
/// Postgres: open watches per store. Each owns a connection of its own (it LISTENs on it), so this
/// is lower than `store_watches_max`, which a backend with no such cost may provision.
pub const store_postgres_watches_max: u32 = 64;
pub const store_postgres_conninfo_bytes_max: u32 = 1024;
pub const store_postgres_schema_bytes_max: u32 = 32;
pub const store_postgres_connect_timeout_s: u32 = 5;
/// How long a statement waits for a lock another transaction holds before ZC-E0208. Writers
/// serialise on one row, each for milliseconds, so this is a stuck-peer limit (like SQLite's).
pub const store_postgres_lock_timeout_ms: u32 = 5000;
pub const store_postgres_statement_timeout_ms: u32 = 30 * 1000;
/// A transaction left open this long by a client that has gone silent is ended by the server, so
/// the writer lock it holds cannot block every other writer for as long as TCP takes to notice.
pub const store_postgres_idle_txn_ms: u32 = 30 * 1000;
/// How often a Postgres watch re-reads the log when no NOTIFY woke it: the bound on what a lost
/// notification costs. A watch never depends on one arriving.
pub const store_watch_notify_fallback_ms: u32 = 250;
/// A watch that finds a hole in the revisions re-reads this many times, `store_watch_hole_wait_ms`
/// apart, before it raises ZC-B0001 instead of skipping the missing revision.
pub const store_watch_hole_retries_max: u32 = 3;
pub const store_watch_hole_wait_ms: u32 = 5;
/// Rows one compaction step deletes before it lets other writers in.
pub const store_compact_batch_rows: u32 = 1000;
/// The arena a server request or a reconcile pass gets; exceeding it is an operating error.
pub const request_arena_bytes_max: u32 = 16 * 1024 * 1024;

// ---- Runtime -------------------------------------------------------------------------------

pub const runtime_command_words_max: u32 = 64;
pub const runtime_env_count_max: u32 = 64;
pub const runtime_labels_max: u32 = 16;
pub const runtime_handles_max: u32 = 512;
pub const runtime_events_batch_max: u32 = 64;
pub const label_key_bytes_max: u32 = 63;
pub const label_value_bytes_max: u32 = 253;
/// "b3:" and 64 hex digits; shorter forms are fixture names in the fake runtime.
pub const image_digest_bytes_max: u32 = 67;

// ---- Controllers, the agent step, the API (core) -------------------------------------------

pub const service_name_bytes_max: u32 = 48;
pub const node_name_bytes_max: u32 = 63;
/// Replica ids are `<service>-<n>` with `n` under a billion, so an id is at most 58 bytes and fits
/// the container-name rule of 63.
pub const replica_number_max: u32 = 999_999_999;
pub const services_max: u32 = 256;
pub const replicas_max: u32 = runtime_handles_max;
pub const nodes_max: u32 = 64;
/// Records one reconcile pass reads: a service holds at most this many replicas.
pub const replicas_per_service_max: u32 = 128;
/// Writes one controller step makes at most (each is a transaction of at most
/// `store_txn_ops_max` operations): the step stops, says so, and runs again for the rest.
pub const controller_txns_per_step_max: u32 = 64;
/// How many of a service's newest decisions the hold check reads to see whether a failure was
/// already explained.
pub const decisions_scan_max: u32 = 16;
/// The agent's wait between looks at the runtime when nothing wakes it sooner.
pub const agent_resync_ms: u32 = 1000;
pub const node_lease_ttl_ms: u32 = 10 * 1000;
/// A grace period for a stop, then a kill.
pub const stop_grace_ms: u32 = 5000;
/// Containers whose stop the agent has asked for and is waiting on.
pub const agent_stops_max: u32 = runtime_handles_max;
/// What the scheduler gives a replica whose service sets no limits (api.md item 6).
pub const request_default_cpu_millis: u32 = 250;
pub const request_default_memory_bytes: u64 = 128 * 1024 * 1024;
/// Decision retention (docs/keys.md): the newest 200 per subject, at most 7 days; 24 hours after
/// the subject is gone.
pub const decisions_per_subject_max: u32 = 200;
pub const decision_age_ms_max: u64 = 7 * 24 * 60 * 60 * 1000;
pub const decision_gone_age_ms_max: u64 = 24 * 60 * 60 * 1000;
/// How often the controller looks for decisions to drop.
pub const retention_interval_ms: u32 = 60 * 1000;
pub const retention_batch_pairs: u32 = store_txn_ops_max / 2;
pub const retention_batches_max: u32 = 32;
/// Decisions that may be written by one step, so a decision id's counter cannot wrap inside one.
pub const decision_counter_modulus: u32 = 10_000;
/// The widest `at_ms` a decision id holds: 13 digits.
pub const decision_time_ms_max: u64 = 9_999_999_999_999;
pub const request_id_bytes_min: u32 = 8;
pub const request_id_bytes_max: u32 = 64;
pub const api_request_bytes_max: u32 = 64 * 1024;
pub const api_query_params_max: u32 = 16;
pub const api_watch_prefixes_max: u32 = 8;
pub const api_watch_timeout_ms_max: u32 = 25_000;
pub const api_list_limit_max: u32 = 500;
pub const api_response_bytes_max: u32 = 8 * 1024 * 1024;
/// Steps one `why` chain can have: decisions chain by cause, and each decision is read once.
pub const why_steps_max: u32 = 64;
pub const why_text_bytes_max: u32 = 480;

// ---- Server shell (zcube-server) -----------------------------------------------------------

/// Connections the HTTP server serves at once; the next one is answered 503 and closed.
pub const http_connections_max: u32 = 64;
/// Long-poll watches held open at once. Each holds one store watch (and, on Postgres, one
/// connection), so this stays well under `store_postgres_watches_max`.
pub const http_holds_max: u32 = 24;
/// Refusals being delivered at once to connections the server will not serve. Each has a task
/// and a slot of its own, so a flood of refused clients cannot starve the served ones; one past
/// this is closed without a reply.
pub const http_refusals_max: u32 = 4;
/// The request line and headers together; a larger head is 431.
pub const http_head_bytes_max: u32 = 16 * 1024;
/// A request body; a larger one is 413 and the connection is closed.
pub const http_body_bytes_max: u32 = api_request_bytes_max;
/// A connection that sends nothing for this long while the server waits for a request (or the
/// rest of one) is closed. It does not apply while a long poll is held.
pub const http_idle_timeout_ms: u32 = 10 * 1000;
/// How often the idle watchdog of a connection looks.
pub const http_watchdog_ms: u32 = 500;
/// Requests served on one connection before the server closes it.
pub const http_requests_per_connection_max: u32 = 1000;
pub const http_write_buffer_bytes: u32 = 16 * 1024;
/// What the server reads and discards from a client whose connection it is closing, so that the
/// close is not a reset that eats the reply.
pub const http_linger_bytes_max: u32 = 1024 * 1024;
/// The longest a held long poll sleeps in one wait on the store, so it notices a stop request.
pub const http_hold_slice_ms: u32 = 1000;
pub const server_header_name_bytes_max: u32 = 64;
/// The server's own threads beyond one per connection: the accept loop, the controller loop.
pub const server_threads_extra: u32 = 4;
/// How often the controller loop expires leases, and compacts the store.
pub const server_maintenance_ms: u32 = 1000;
pub const server_compact_ms: u32 = 60 * 1000;
/// Revisions of history the compaction keeps, so a console that was away for a minute can still
/// resume its watch and a paged list can finish.
pub const server_compact_keep_revisions: u32 = 1000;
/// After a failed step the controller waits this long, doubling up to the maximum.
pub const server_retry_ms_min: u32 = 250;
pub const server_retry_ms_max: u32 = 5000;
/// A repeated failure is shown again only after this long (a new code is shown at once).
pub const server_report_ms: u32 = 30 * 1000;
pub const config_bytes_max: u32 = 16 * 1024;
pub const config_path_bytes_max: u32 = 1024;
pub const listen_bytes_max: u32 = 128;
pub const store_spec_bytes_max: u32 = 1100;
/// The controller loop and the accept loop may not wait on a clock-less store longer than this
/// between looks (the memory store never blocks in `Watch.next`).
pub const server_poll_ms: u32 = 10;
/// How long a stopping server waits for its connections before it closes them.
pub const server_stop_ms: u32 = 2000;

// ---- Agent shell and FakeRuntime (zcube-agent) ---------------------------------------------

/// The agent's long poll of the server in one wait: short, so that a container that ended on
/// this node is noticed within about this long, which is the resolution of a purely local event.
pub const agent_watch_slice_ms: u32 = 250;
/// A reply from the server that the agent will read: the API's own bound.
pub const agent_response_bytes_max: u32 = api_response_bytes_max;
/// The agent's request: a transaction of observed records fits in it.
pub const agent_request_bytes_max: u32 = api_request_bytes_max;
/// A request on an open connection may take this long beyond its long poll.
pub const agent_io_timeout_ms: u32 = 10 * 1000;
/// A replica list and an observed list each hold at most this many records: one page of a store
/// list, because the agent endpoints do not page.
pub const agent_node_replicas_max: u32 = store_list_limit_max;
/// Observed records one report carries: one transaction.
pub const agent_report_ops_max: u32 = store_txn_ops_max;
/// A flag value or a path given to the agent.
pub const agent_arg_bytes_max: u32 = 4096;
pub const agent_args_max: u32 = 64;
/// Digests in `fixtures/images.zon`.
pub const fixture_images_max: u32 = 64;
pub const fixtures_bytes_max: u32 = 16 * 1024;
/// `start` waits this long for the supervisor to report that the command runs.
pub const fake_start_timeout_ms: u32 = 10 * 1000;
/// The pause between looks while `start` waits and while `events` waits.
pub const fake_poll_ms: u32 = 10;
/// Containers kept in the state directory, running or not. A start past this drops the oldest
/// stopped one first; with none to drop it is ZC-E0502.
pub const fake_containers_max: u32 = runtime_handles_max;
/// A container's spec file, run record and fault file.
pub const fake_file_bytes_max: u32 = 64 * 1024;
/// How long a stop waits, after the kill, for the supervisor to write the run record.
pub const fake_reap_ms: u32 = 2000;
/// Supervisors this agent process started and has not yet reaped.
pub const fake_children_max: u32 = runtime_handles_max;
/// The names a container directory may hold; anything else in the state directory is ignored.
pub const fake_dir_entries_max: u32 = 4 * runtime_handles_max;

// ---- The zcube command line and its bundles --------------------------------------------------

/// Where the command line looks for zcube-server (docs/cli.md): the same default the server
/// listens on.
pub const cli_server_default = "127.0.0.1:7070";
pub const cli_args_max: u32 = 64;
pub const cli_arg_bytes_max: u32 = 1024;
/// A service file: well under `api_request_bytes_max`, so the JSON made from it fits one request.
pub const service_file_bytes_max: u32 = 32 * 1024;
/// The longest the command line waits for a reply; a watch is never used by it.
pub const cli_reply_timeout_ms: u32 = 30 * 1000;
pub const cli_reply_bytes_max: u32 = api_response_bytes_max;
/// Diagnostics one command reports at most (the server may send several in one reply).
pub const cli_diagnostics_max: u32 = 8;
/// Pages of 500 keys one listing reads at most: 8000 records, well over `replicas_max`.
pub const cli_list_pages_max: u32 = 16;
pub const cli_rows_max: u32 = 2048;
/// The line `zcube apply` reads for its confirmation.
pub const cli_answer_bytes_max: u32 = 64;
pub const cli_user_bytes_max: u32 = 64;
/// The file in the state directory that remembers the last failure (`zcube bundle --last`).
pub const last_failure_bytes_max: u32 = 64 * 1024;
pub const bundles_dir_name = "bundles";
pub const state_dir_name = "zcube";
pub const last_failure_file_name = "last-failure.json";

/// A bundle (DIAGNOSTICS.md, "Bundles"): files are staged in one fixed workspace, cut at
/// `bundle_file_bytes_max`, and written through the tar and gzip writers into a second buffer.
pub const bundle_file_bytes_max: u32 = 128 * 1024;
pub const bundle_files_max: u32 = 24;
pub const bundle_manifest_bytes_max: u32 = 12 * 1024;
pub const bundle_stage_bytes_max: u32 = 1024 * 1024;
pub const bundle_gz_bytes_max: u32 = 1024 * 1024 + 64 * 1024;
pub const bundle_secrets_max: u32 = 64;
pub const secret_value_bytes_min: u32 = 4;
pub const secret_value_bytes_max: u32 = 1024;
pub const environment_entries_max: u32 = 1024;
pub const timestamp_bytes: u32 = 20;
/// Store keys read for a bundle: the subject's records, a page each.
pub const bundle_keys_pages_max: u32 = 4;
pub const bundle_name_bytes_max: u32 = timestamp_bytes + 1 + 3 + service_name_bytes_max + 20;
pub const errors_page_bytes_max: u32 = 24 * 1024;

// ---- Test and demo tooling (agent-smoke, demo-c0) ---------------------------------------------

/// A container's name as the host tooling reads it from the state directory (`hello-12`).
pub const demo_name_bytes_max: u32 = 64;

comptime {
    assert(exit_ok == 0);
    assert(exit_internal == 70);
    assert(diag_command_bytes_max <= diag_field_bytes_max);
    assert(diag_summary_bytes_max < diag_wrap_columns);
    assert(diag_explanation_line_bytes_max < diag_wrap_columns);
    assert(diag_code_bytes_max == "ZBX-E0501".len);
    assert(store_value_bytes_max >= store_key_bytes_max);
    assert(store_page_bytes_max >= store_value_bytes_max);
    assert(store_page_bytes_max + store_value_bytes_max <= request_arena_bytes_max);
    assert(store_txn_ops_max * store_value_bytes_max <= request_arena_bytes_max);
    assert(store_list_limit_max > 0);
    assert(store_lease_keys_max <= store_watch_batch_max);
    assert(store_txn_ops_max <= store_watch_batch_max);
    assert(lease_ttl_ms_min < lease_ttl_ms_max);
    assert(runtime_events_batch_max <= runtime_handles_max);
    assert(store_watch_poll_ms > 0);
    assert(store_watch_poll_ms < lease_ttl_ms_min);
    assert(store_sqlite_busy_ms > store_watch_poll_ms);
    assert(store_compact_batch_rows > 0);
    assert(store_postgres_watches_max <= store_watches_max);
    assert(store_postgres_connections_max > 0);
    assert(store_watch_notify_fallback_ms >= store_watch_poll_ms);
    assert(store_postgres_lock_timeout_ms < store_postgres_statement_timeout_ms);
    assert(store_postgres_statement_timeout_ms <= store_postgres_idle_txn_ms);
    assert(store_watch_hole_retries_max > 0);
    assert(store_postgres_schema_bytes_max + "zcube_".len < 63); // A NOTIFY channel is a name.
    assert(replicas_per_service_max <= replicas_max);
    assert(service_name_bytes_max + 1 + 9 <= 63); // "<service>-<n>" fits a container name.
    assert(retention_batch_pairs * 2 <= store_txn_ops_max);
    assert(decisions_scan_max <= store_list_limit_max);
    assert(request_id_bytes_min < request_id_bytes_max);
    assert(api_list_limit_max <= store_list_limit_max);
    assert(node_lease_ttl_ms >= lease_ttl_ms_min);
    assert(node_lease_ttl_ms <= lease_ttl_ms_max);
    assert(agent_resync_ms < node_lease_ttl_ms);
    assert(decision_counter_modulus == 10_000); // Four digits in the id.
    assert(api_response_bytes_max <= request_arena_bytes_max);
    assert(controller_txns_per_step_max > 0);
    // The controller's watch, and one spare, besides the held watches.
    assert(http_holds_max + 2 < store_postgres_watches_max);
    assert(http_holds_max <= http_connections_max);
    assert(http_head_bytes_max < http_body_bytes_max);
    assert(http_watchdog_ms < http_idle_timeout_ms);
    assert(http_hold_slice_ms <= api_watch_timeout_ms_max);
    assert(server_retry_ms_min <= server_retry_ms_max);
    assert(server_poll_ms >= store_watch_poll_ms);
    assert(store_spec_bytes_max > store_postgres_conninfo_bytes_max);
    assert(agent_watch_slice_ms < agent_resync_ms);
    assert(agent_watch_slice_ms < api_watch_timeout_ms_max);
    assert(agent_report_ops_max <= store_txn_ops_max);
    assert(agent_node_replicas_max <= replicas_max);
    assert(agent_node_replicas_max <= store_list_limit_max); // One page: the reply is not paged.
    assert(fake_containers_max <= runtime_handles_max);
    assert(fake_poll_ms < fake_start_timeout_ms);
    assert(fake_file_bytes_max <= store_value_bytes_max);
    assert(agent_io_timeout_ms > agent_watch_slice_ms);

    assert(service_file_bytes_max < api_request_bytes_max);
    assert(cli_reply_bytes_max <= request_arena_bytes_max);
    assert(cli_list_pages_max * api_list_limit_max >= replicas_max);
    assert(bundle_file_bytes_max * 2 < bundle_stage_bytes_max);
    assert(bundle_stage_bytes_max + 16 * 1024 <= bundle_gz_bytes_max);
    assert(bundle_files_max * 1024 < bundle_stage_bytes_max); // The tar headers.
    assert(bundle_manifest_bytes_max < bundle_stage_bytes_max);
    assert(secret_value_bytes_min < secret_value_bytes_max);
    assert(bundle_secrets_max * secret_value_bytes_max < bundle_stage_bytes_max);
    assert(last_failure_bytes_max <= bundle_file_bytes_max);
    assert(timestamp_bytes == "2026-10-23T22-41-07Z".len);
    assert(6 * 1024 + 6 * diag_explanation_bytes_max + 2048 <= errors_page_bytes_max);
}
