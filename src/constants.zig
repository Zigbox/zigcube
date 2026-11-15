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
/// `zcube job get --wait` ends with the job's ending, in codes that are none of the blame codes
/// above, so a script can tell "the job failed" from "the command did" (docs/cli.md).
pub const exit_job_exited: u8 = 10;
pub const exit_job_failed: u8 = 11;
pub const exit_job_cancelled: u8 = 12;

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
/// "ZC-" and a letter with four digits; Zigbox's "ZBX-E0410" is the longest code on the wire.
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
pub const runtime_env_count_max: u32 = 16;
pub const runtime_labels_max: u32 = 8;
pub const runtime_handles_max: u32 = 512;
pub const runtime_events_batch_max: u32 = 64;
pub const label_key_bytes_max: u32 = 32;
pub const label_value_bytes_max: u32 = 128;
/// "b3:" and 64 hex digits; shorter forms are fixture names in the fake runtime.
pub const image_digest_bytes_max: u32 = 67;
/// The longest OCI reference a service's `source` may hold: Zigbox's `reference_bytes_max`
/// (`constants.zig` in the pinned package), the length its `pull.parse_reference` accepts.
pub const source_bytes_max: u32 = 1024;

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
/// Generations of a service `/history` keeps (owner,
/// docs/decisions/2026-11-05-c3-owner-answers.md): an apply that adds one past it deletes the
/// oldest. Rolling back to a deleted one is ZC-E0128.
pub const history_generations_max: u32 = 16;
/// History keys one read of a service's history takes at most. Every writer keeps
/// `history_generations_max`; the slack covers keys a crash between transactions could leave.
pub const history_scan_max: u32 = 64;
/// The longest a health check may wait between runs, and its `start_period_ms`: as long as the
/// server waits for a lost node (`lost_grace_ms_max`), the longest the cluster leaves a replica
/// unjudged elsewhere (docs/decisions/2026-11-13-c3-health-rollout-bounds.md).
pub const health_interval_ms_max: u32 = lost_grace_ms_max;
/// The longest a health check's thresholds may take to settle a verdict, `threshold *
/// interval_ms`: a day, the longest deadline a job may have (`job_deadline_ms_max`).
pub const health_verdict_ms_max: u64 = job_deadline_ms_max;
/// The longest `rollout.progress_deadline_ms` (which bounds `ready_timeout_ms` and
/// `min_ready_ms` too): a day, the longest deadline a job may have.
pub const rollout_deadline_ms_max: u32 = @intCast(job_deadline_ms_max);
/// How often one rollout's new replicas may die before the rollout fails (ZC-E0304): more than
/// this many deaths of new replicas since the rollout began or was last resumed fail it. A
/// replica is replaced under a new id, not restarted in place, so a "restart" is a new replica's
/// container ending for any reason the release can cause: not a held start (failed at once) and
/// not its node's loss (docs/decisions/2026-11-13-c3-rollout-restarts-max.md).
pub const rollout_restarts_max: u32 = 3;
/// The longest `rollout.grace_ms` an old replica gets to stop: a job's longest stop grace.
pub const rollout_grace_ms_max: u32 = job_grace_ms_max;
/// Writes one controller step makes at most (each is a transaction of at most
/// `store_txn_ops_max` operations): the step stops, says so, and runs again for the rest.
pub const controller_txns_per_step_max: u32 = 64;
/// How many of a service's newest decisions the hold check reads to see whether a failure was
/// already explained.
pub const decisions_scan_max: u32 = 16;
/// The agent's wait between looks at the runtime when nothing wakes it sooner.
pub const agent_resync_ms: u32 = 1000;
pub const node_lease_ttl_ms: u32 = 10 * 1000;
/// The fencing constants of docs/briefs/c1.md ("Settled here") and docs/authority.md §3. The
/// agent stops its containers at `s + ttl - fence_margin`; the node controller declares a node
/// lost at expiry and places elsewhere `lost_grace_ms` later.
pub const lease_ttl_ms: u32 = node_lease_ttl_ms;
/// How long the agent waits for containers to stop, when it fences, before it kills them.
pub const fence_stop_ms: u32 = 2000;
/// The bound on the difference of two hosts' clock rates, in parts per thousand (1 %).
pub const clock_skew_per_mille: u32 = 10;
pub const fence_margin_ms: u32 = 3000;
/// The least time a lease must leave between its last acknowledged keepalive and the fence
/// (`ttl - fence_margin`): room for a renewal to be sent, answered and recorded. With less the
/// agent renews on every pass and still fences (issue #78: `--lease-ttl-ms=3001` never settles).
/// 5,000 makes the shortest admitted ttl 8,000 ms, the shortest the simulator draws (owner,
/// 2026-11-06): the admitted and the drawn ranges agree. The renewal falls at a third of the
/// ttl, at least 2,334 ms before the fence, for the pass, the round trip and the commit.
pub const fence_window_min_ms: u32 = 5000;
/// The time `fencing.renew_after_ms` leaves between a renewal due and the fence, at the least.
pub const renew_slack_min_ms: u32 = 1000;
/// How often a fencing agent looks at its containers while it waits for them to stop.
pub const fence_poll_ms: u32 = 100;
pub const lost_grace_ms: u32 = 1000;
/// The longest `zcube-server --lost-grace-ms` accepts: an hour.
pub const lost_grace_ms_max: u32 = 60 * 60 * 1000;
/// What the margin leaves for the kernel to deliver SIGKILL and the process to exit.
pub const fence_kill_latency_ms: u32 = 900;
/// Bytes a decision's `cause_evidence` may take.
pub const decision_evidence_bytes_max: u32 = 1024;
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
/// Pull records (`/pulls/<node>/<tree>`, docs/keys.md): the newest this many per node and at most
/// 30 days; a pass reads at most `store_list_limit_max` x `pulls_pages_per_pass_max` records.
pub const pulls_per_node_max: u32 = 100;
pub const pull_age_ms_max: u64 = 30 * 24 * 60 * 60 * 1000;
pub const pulls_pages_per_pass_max: u32 = 4;
/// Peers one pull record names, each way (bytes given, struck); the rest are summed in none.
pub const pull_peers_max: u32 = fetch_peers_max;
/// The body of `POST /v1/agent/nodes/{node}/pulls`: a record of at most this many bytes and the
/// tenure, with room for the names.
pub const pull_request_bytes_max: u32 = 8 * 1024;
/// Pull records an agent publishes in one step, so a burst of finished pulls cannot hold it.
pub const pulls_per_step_max: u32 = 8;
/// How often the controller looks for pull records to drop.
pub const pulls_interval_ms: u32 = 5 * 60 * 1000;
/// How long retention of pull records waits after a pass failed, before the next try.
pub const pulls_retry_ms: u32 = 60 * 1000;
/// How often the controller looks for decisions to drop.
pub const retention_interval_ms: u32 = 60 * 1000;
pub const retention_batch_pairs: u32 = store_txn_ops_max / 2;
pub const retention_batches_max: u32 = 32;
/// Reachability (authority.md §5): the decisions one pass pins, at most. A pass that would pin
/// more drops nothing from live subjects (fail safe) and tries again at the next interval.
pub const retention_pinned_max: u32 = 8192;
/// The distinct actions of one live subject, each with a root: more is the same fail safe.
pub const retention_actions_per_subject_max: u32 = 16;
/// Memory one pass reads index pages and decisions through, reused for each: a page that does
/// not fit is the same fail safe.
pub const retention_scratch_bytes: u32 = 1024 * 1024;
/// Decisions that may be written by one step, so a decision id's counter cannot wrap inside one.
pub const decision_counter_modulus: u32 = 10_000;
/// The largest instance number a shell hands the control plane. Each controller's decision source
/// is `instance*4 + role` (below 0x8000 up to here) and the job controller's is
/// `0x8000 | instance`, so no two controllers of any instance share one.
pub const controller_instance_max: u16 = 8191;
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
pub const http_connections_max: u32 = 96;
/// Long-poll watches held open at once. Each holds one store watch (and, on Postgres, one
/// connection), so this stays well under `store_postgres_watches_max`. 50 agents hold one each
/// (owner, 2026-11-02); Postgres then needs `max_connections` of at least 80.
pub const http_holds_max: u32 = 50;
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
/// The remembered revision is saved at most this often (a lagging copy is safe, only weaker).
pub const verified_save_ms: u32 = 1000;
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
/// The longest the command line waits for a piece of a reply.
pub const cli_reply_timeout_ms: u32 = 30 * 1000;
/// `zcube job get --wait` looks again this often (a GET each time: a held watch would take one of
/// the server's `http_holds_max` for every waiting command).
pub const cli_job_poll_ms: u32 = 1000;
/// `zcube job watch` asks the server to hold a poll this long: under both the server's cap and
/// `cli_reply_timeout_ms`, so an empty answer arrives before the command gives up on it.
pub const cli_job_watch_hold_ms: u32 = 20 * 1000;
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

// ---- `zcube local up|down` (src/cli_local.zig) ------------------------------------------------

/// The node the local agent registers as.
pub const local_node_name = "local";
/// The first port `local up` tries, then the next ones: 7070 is the CLI's own default.
pub const local_port_first: u16 = 7070;
pub const local_port_tries_max: u16 = 32;
/// How long `local up` waits for the server to answer and the node to register.
pub const local_up_wait_ms: u32 = 20 * 1000;
/// How long `local down` waits after SIGTERM before SIGKILL.
pub const local_stop_wait_ms: u32 = 10 * 1000;
pub const local_poll_ms: u32 = 50;
/// The capacity the local agent declares; the fake runtime isolates nothing, so these are only
/// what the scheduler may place.
pub const local_cpu_millis: u32 = 4000;
pub const local_memory_bytes: u64 = 8 * 1024 * 1024 * 1024;
/// A pid file, a command line from /proc and an address file are each read into a buffer of
/// this size; longer content is not ours.
pub const local_file_bytes_max: u32 = state_path_bytes_max + 256;
/// A server or agent command line holds the local directory at most twice (the agent's
/// `--state-dir` and `--images`), plus the fixed arguments.
pub const local_cmdline_bytes_max: u32 = 2 * state_path_bytes_max + 512;
/// How long `local up` and `local down` wait for another of them to finish: more than an `up`
/// that waits for both processes and a `down` that stops both.
/// Descriptors above stderr are marked close-on-exec up to this number before a start.
pub const local_fd_scan_max: i32 = 4096;
pub const local_lock_wait_ms: u32 = 60 * 1000;

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

// ---- The simulation fleet's reporter (`sim_fleet`, ops/sim-fleet/README.md) ----------------

/// One round's input: a few lines per failing seed of every worker's batch.
pub const fleet_input_bytes_max: u32 = 1024 * 1024;
/// Failures one round may report; more is refused as input that is not the runner's.
pub const fleet_round_failures_max: u32 = 4096;
pub const fleet_state_bytes_max: u32 = 1024 * 1024;
pub const fleet_token_bytes_max: u32 = 4096;
/// Distinct failures the state file remembers as filed. Reaching it is an operating error.
pub const fleet_filed_max: u32 = 1024;
/// UTC days the state file keeps counts for; the oldest is dropped past this.
pub const fleet_days_kept: u32 = 31;
/// The run kinds a day is broken down by (sim-cluster, sim-c1, sim-swarm, sim-canary) with room
/// for four more; `sim_fleet_issue.kinds` asserts it fits. Only a bound on reading the state file.
pub const fleet_kinds_max: u32 = 8;
/// Distinct failures counted per day for the tracker comment; more are in the day's total only.
pub const fleet_seen_per_day_max: u32 = 256;
/// Comments one failure gets per UTC day, and never two for the same commit.
pub const fleet_comments_per_failure_per_day_max: u32 = 4;
/// Other seeds of a round listed in an issue or comment.
pub const fleet_seeds_listed_max: u32 = 20;
/// The longest failing check (sim_cluster's own buffer) or crash message kept.
pub const fleet_check_bytes_max: u32 = 256;
/// A GitHub response body; 100 issues with long bodies fit.
pub const fleet_response_bytes_max: u32 = 8 * 1024 * 1024;
/// Pages of 100 labelled issues searched for a marker when the state file is lost.
pub const fleet_find_pages_max: u32 = 5;
pub const fleet_find_page_size: u32 = 100;
/// How long GitHub writes stop after a rate limit that names no wait, and the most any wait is
/// honoured for.
pub const fleet_hold_seconds_default: u32 = 3600;
pub const fleet_hold_seconds_max: u32 = 24 * 3600;

// ---- Swarm: the store summary and the fetch plan (docs/swarm.md, C2 slice 4) -------------------

/// One chunk of Zigbox's store (`store_chunk_bytes`, 1 MiB): the unit a peer serves and a fetch
/// verifies.
pub const swarm_chunk_bytes: u32 = 1024 * 1024;
/// The chunks a node's filter is sized for: 64 Ki of them, 64 GiB of distinct 1 MiB chunks.
pub const summary_chunks_capacity: u32 = 64 * 1024;
/// Filter bits per chunk of capacity. With `summary_filter_hashes` = 7 hash functions the
/// false-positive rate is (1 - e^(-7/10))^7 = 0.82 %, under the 1 % c2.md asks for.
pub const summary_filter_bits_per_chunk: u32 = 10;
pub const summary_filter_hashes: u32 = 7;
/// The filter's size at capacity: 64 Ki * 10 bits = 80 KiB, under `store_value_bytes_max`
/// (256 KiB) together with the sketches below.
pub const summary_filter_bytes_max: u32 =
    summary_chunks_capacity * summary_filter_bits_per_chunk / 8;
/// A sketch keeps the K smallest keys of a tree's distinct chunks. The estimate of the share a node
/// holds is a ratio over the target's samples below the smallest sketch limit, at most K of them:
/// about sqrt(0.25 / 64) = 6.25 % of the tree's size when the held trees are no larger than the
/// target, and worse as many held trees push their limits down (docs/swarm.md).
pub const summary_sketch_keys: u32 = 64;
/// A key is 8 bytes and its chunk's size 4: 64 * 12 = 768 bytes a tree, with its digest and
/// totals about 820. At most 32 held trees: 26 KiB, so filter and sketches stay under
/// `store_value_bytes_max`.
pub const summary_trees_max: u32 = 32;
pub const summary_sketch_entry_bytes: u32 = 12;
/// The summary is JSON and its Bloom filter and samples are hex, so each byte is two digits. A
/// tree's entry adds its digest (`sha256:` and 64 digits), the keys, two numbers and quotes; the
/// record adds its own members. Both are rounded up.
pub const summary_tree_json_overhead_bytes: u32 = 256;
pub const summary_json_overhead_bytes: u32 = 256;
/// The largest summary record as stored, in JSON.
pub const summary_json_bytes_max: u32 = summary_filter_bytes_max * 2 +
    summary_trees_max * (summary_sketch_keys * summary_sketch_entry_bytes * 2 +
        summary_tree_json_overhead_bytes) + summary_json_overhead_bytes;
/// The body of `PUT /v1/agent/nodes/{node}/store`: the record, the tenure and the lease (two
/// numbers and their names). The one agent request that is larger than `agent_request_bytes_max`.
pub const summary_request_bytes_max: u32 = summary_json_bytes_max + 128;

/// Peers one fetch considers (a filter each), and chunks one fetch plans (a tree of 64 GiB).
pub const fetch_peers_max: u32 = 16;
/// A full tree digest: `b3:` and 64 hex digits.
pub const tree_digest_bytes: u32 = 3 + 64;
/// Peers discovery may offer a fetch; the worker ranks them by the chunks their filters claim
/// and keeps `fetch_peers_max` of them.
pub const fetch_candidates_max: u32 = 64;
/// Peers asked for the tree's chunk list before the registry is (each may take a request
/// timeout, so this bounds how long the list can take).
pub const fetch_list_peers_max: u32 = 4;
/// One fetch ends in an error after this long, whatever it is doing (a 64 GiB tree at the
/// node's rate cap takes about 17 minutes).
pub const fetch_total_ms: u32 = 30 * 60 * 1000;
/// The Zigbox supervisor kills a `zcube-agent fetch` that is still running this long after it
/// started: the fetch's own limit and a minute for it to say why it failed.
pub const zigbox_fetch_deadline_ms: u32 = fetch_total_ms + 60 * 1000;
/// After the fetch's process group is sent SIGKILL (at the deadline, or after the fetch ended),
/// how long the supervisor waits for every process of it to be gone. One still there then is in
/// uninterruptible sleep and may still write the store, so no pull starts (ZC-E0515).
pub const zigbox_fetch_kill_wait_ms: u32 = 5 * 1000;
/// How many times `process_session.kill_all` reads `/proc` for a session's processes: a process
/// forked while the first read went by is found by the next.
pub const session_kill_rounds: u32 = 3;
/// The most `/proc` entries one read looks at: Linux's largest `pid_max` (2^22) and the
/// non-process entries beside them.
pub const proc_entries_max: u32 = (1 << 22) + 1024;

comptime {
    assert(cli_job_watch_hold_ms <= api_watch_timeout_ms_max);
    assert(cli_job_watch_hold_ms < cli_reply_timeout_ms);
    assert(exit_job_exited > exit_external);
    assert(exit_job_exited < exit_job_failed);
    assert(exit_job_failed < exit_job_cancelled);
    assert(exit_job_cancelled < exit_internal);
    assert(zigbox_fetch_kill_wait_ms < zigbox_fetch_deadline_ms);
    assert(session_kill_rounds >= 2);
}
/// The wait before a fetch on a node whose last fetch failed, doubling from the base to the cap
/// (`fetch_backoff.zig`), so an unreachable tree does not make replicas churn at the speed of the
/// refusals.
pub const fetch_backoff_base_ms: u32 = 1000;
pub const fetch_backoff_cap_ms: u32 = 5 * 60 * 1000;
/// A temporary file of the chunk store older than this was left by a writer that died
/// (`dir_images.zig`); the fetch deadline is far shorter.
pub const dir_temp_stale_ms: u64 = 2 * @as(u64, fetch_total_ms);
/// Entries one sweep of a store directory looks at.
pub const dir_sweep_entries_max: u32 = 1 << 20;
/// A wait for the back-off sleeps in slices of this size, so a stop is noticed.
pub const fetch_backoff_slice_ms: u32 = 100;
/// Digests whose fetch streak a node keeps (`fetch_backoff.zig`); a new one drops the oldest.
pub const fetch_streak_digests_max: u32 = 16;
pub const fetch_chunks_max: u32 = summary_chunks_capacity;
/// A tree's chunk list as text: `<64 hex> <bytes>` and a newline per chunk, at most 80 bytes each.
pub const tree_list_bytes_max: u32 = fetch_chunks_max * 80;
/// With no peer holding a chunk, the plan waits this long from its start for a filter to show it
/// (another node may be fetching it, c2.md O5), then goes to the registry.
pub const fetch_peer_wait_ms: u32 = 30_000;
/// A fetch waiting for another node's registry pull (O5) re-reads `/node-store` this often.
pub const fetch_peer_poll_ms: u32 = 1000;
/// A fetch says how far it is at most this often (fetch.log).
pub const fetch_progress_ms: u32 = 10_000;
/// A request not answered by then is a timeout.
pub const fetch_request_timeout_ms: u32 = 10_000;
/// Requests in flight in all, and to one peer.
pub const fetch_in_flight_max: u32 = 8;
pub const fetch_in_flight_per_peer_max: u32 = 2;
/// A peer that times out this many times in a row is given up for this fetch.
pub const fetch_peer_timeouts_max: u32 = 3;
/// Tries of one chunk at the registry before the fetch fails.
pub const fetch_registry_attempts_max: u32 = 4;
/// Byte-rate caps: one peer's, and the node's (peers and registry together).
pub const fetch_peer_rate_bytes_per_s: u32 = 32 * 1024 * 1024;
pub const fetch_node_rate_bytes_per_s: u32 = 64 * 1024 * 1024;

// ---- Peer identity and the handshake (docs/peer.md, C2 slice 6a) -----------------------------

/// A node credential lives this long from its issuer's wall clock; the agent renews at half.
pub const peer_credential_ttl_ms: u64 = 24 * 60 * 60 * 1000;
/// The longest life a verifier accepts, so a CA bug or a bad clock cannot mint a forever key.
pub const peer_credential_ttl_ms_max: u64 = 7 * peer_credential_ttl_ms;
/// Wall-clock disagreement tolerated between two nodes, and between a node and the CA.
pub const peer_clock_skew_ms: u64 = 60 * 1000;
/// Plaintext of one record. A 1 MiB chunk is sent as 64 of them.
pub const peer_record_bytes_max: u32 = 16 * 1024;
/// Records a direction may carry before the connection must be replaced (2^32).
pub const peer_record_counter_max: u64 = 1 << 32;
/// The `revoked` file and the key files are small; this bounds the read.
pub const peer_file_bytes_max: u32 = 32 * 1024;
/// Names on the server's `revoked` list.
pub const peer_revoked_max: u32 = 256;
/// A credential request body: `{"node_key": "<64 hex>"}` with room to spare.
pub const peer_join_request_bytes_max: u32 = 512;
/// A failed join or renewal is tried again after this long.
pub const peer_join_retry_ms: u32 = 5 * 1000;
/// One join call waits this long at most (less near the lease's fence).
pub const peer_join_timeout_ms: u32 = 3 * 1000;
/// Handshakes the peer server starts for one source address in one window; the next is refused.
/// It bounds unauthenticated public-key work (a few hundred microseconds each), and is sized for
/// a whole cluster behind one NAT address: every fetch connection to this server carries
/// `peer_connection_requests_max` chunks, so even a server serving at 1 GiB/s sees about 16
/// handshakes a second from all its fetchers together, and busy answers add a few more.
pub const peer_handshakes_per_source_max: u32 = 256;
/// Handshakes of one source address that may be unfinished at once; one more is refused. Above
/// one so that the nodes of a cluster behind one NAT address can connect together; well under
/// `peer_handshakes_max`, so that silent strangers of one address hold a few links, not all.
pub const peer_handshakes_pending_per_source_max: u32 = 8;
/// The window the per-source bound counts in.
pub const peer_handshake_window_ms: u64 = 10 * 1000;
/// Sources the limiter tracks at once. A table full of live windows refuses a new source: the
/// cheapest answer to an address flood, and an agent retries.
pub const peer_sources_max: u32 = 256;
/// Peer connections the server serves at once (each owns buffers of about 12 MiB). One more
/// authenticated peer is told it is busy (status 503) and closed.
pub const peer_connections_max: u32 = 4;
/// Serving slots one authenticated node name holds at once; its next connection is told busy
/// (503). An honest fetch keeps one stream per peer, so this is room for two concurrent fetches.
/// Any API client can mint a credential (docs/peer.md), so this bounds a node name, not an
/// attacker: the slot count is what bounds the server.
pub const peer_connections_per_node_max: u32 = 2;
/// Connections the server holds before they are authenticated: a descriptor, a task and a few
/// words each, no buffers. A silent stranger holds one for at most `peer_handshake_ms`; the
/// buffers of a serving slot go to a connection only once it has authenticated.
pub const peer_handshakes_max: u32 = 32;
/// A stranger younger than this is never evicted for a newcomer (the newcomer is closed
/// instead): under a flood, oldest-first eviction would otherwise give every honest handshake a
/// lifetime shorter than a slow link's round trips.
pub const peer_handshake_evict_min_ms: u64 = 750;
/// Time between two times ZC-E0808 is shown, whatever the sources: a flood must not flood a log.
pub const peer_refusal_log_ms: u64 = 10 * 1000;
/// How long a fetch keeps asking a peer whose server said it is busy (status 503) before it
/// takes the answer as a refusal, and the pauses between asks: the first, doubled up to the
/// longest. A busy peer is not a failed one: no timeout, no strike
/// (docs/decisions/2026-11-05-busy-peer-wait.md).
pub const fetch_busy_wait_ms: u32 = 20 * 1000;
pub const fetch_busy_sleep_ms: u32 = 250;
pub const fetch_busy_sleep_max_ms: u32 = 2 * 1000;
/// Time a peer has to finish the handshake.
pub const peer_handshake_ms: u32 = 3 * 1000;
/// Time a served connection waits for its next request before it closes.
pub const peer_idle_ms: u32 = 2 * 1000;
/// Time to send one reply.
pub const peer_reply_ms: u32 = 5 * 1000;
/// Requests one connection serves before the client opens another.
pub const peer_connection_requests_max: u32 = 64;

// ---- X.509 certificates for the mTLS client (docs/briefs/mtls-client.md, slice 1) -------------

/// A certificate in DER, whatever its kind. A CA certificate is about 250 bytes; the largest leaf
/// the writer makes (longest names, `x509_labels_bytes_max` of labels) is checked against this in
/// `x509.zig`. One TLS record carries a whole server flight of at most two of them.
pub const x509_cert_bytes_max: u32 = 1024;
/// Labels in a workload certificate's identity extension.
pub const x509_labels_max: u32 = 16;
pub const x509_label_key_bytes_max: u32 = 63;
pub const x509_label_value_bytes_max: u32 = 256;
/// The sum of every label's key and value, so 16 labels cannot push a leaf past
/// `x509_cert_bytes_max`; the brief's per-label limits alone would allow about 5 KiB.
pub const x509_labels_bytes_max: u32 = 256;
/// A leaf's life: the job's deadline bound. A verifier refuses a longer one (fails closed).
pub const x509_leaf_ttl_ms_max: u64 = 7 * 24 * 60 * 60 * 1000;
/// The CA certificate outlives `--new-ca` anyway.
pub const x509_ca_ttl_ms_max: u64 = 10 * 365 * 24 * 60 * 60 * 1000;
/// A commonName (RFC 5280 `ub-common-name`): a job name, a DNS name or `zcube-ca-<16 hex>`.
pub const x509_cn_bytes_max: u32 = 64;
/// A serial number's content, RFC 5280 allows 20; the writer always makes 16.
pub const x509_serial_bytes_max: u32 = 16;
/// The foreign server profile (docs/mtls.md): RFC 5280's 20 content bytes of serial;
pub const x509_foreign_serial_bytes_max: u32 = 20;
/// sets and attributes in an issuer or subject Name together;
pub const x509_foreign_name_parts_max: u32 = 16;
/// extensions (each OID once, compared with every earlier one);
pub const x509_foreign_extensions_max: u32 = 16;
/// key purposes in extKeyUsage;
pub const x509_foreign_key_purposes_max: u32 = 8;
/// and the longest lifetime: the CA's bound, since another CA's leaf policy is its own.
pub const x509_foreign_ttl_ms_max: u64 = x509_ca_ttl_ms_max;
/// The cluster part of a SPIFFE ID: a sequence of DNS labels.
pub const x509_cluster_bytes_max: u32 = 63;
/// A server leaf's `dNSName`, exact match (no wildcard); it is also the subject CN.
pub const x509_dns_name_bytes_max: u32 = x509_cn_bytes_max;
/// `spiffe://<cluster>/service/<name>`.
pub const x509_spiffe_bytes_max: u32 = 9 + x509_cluster_bytes_max + 9 + node_name_bytes_max;

comptime {
    assert(x509_labels_max * x509_label_key_bytes_max > x509_labels_bytes_max);
    assert(x509_label_key_bytes_max + x509_label_value_bytes_max > x509_labels_bytes_max / 2);
    assert(x509_labels_bytes_max < x509_cert_bytes_max / 2);
    assert(x509_leaf_ttl_ms_max < x509_ca_ttl_ms_max);
    assert(x509_leaf_ttl_ms_max % 1000 == 0);
    assert(x509_ca_ttl_ms_max % 1000 == 0);
    assert(x509_cn_bytes_max >= node_name_bytes_max);
    assert(x509_cn_bytes_max >= 9 + 16);
    assert(x509_serial_bytes_max == 16);
    assert(x509_foreign_serial_bytes_max == 20);
    assert(x509_foreign_extensions_max <= 64);
    assert(x509_spiffe_bytes_max < 256);
    assert(x509_cert_bytes_max < 65536);
}

// ---- TLS 1.3 record layer for the mTLS client (docs/briefs/mtls-client.md, slice 3) -----------

/// RFC 8446 section 5.1: the most content bytes one record carries.
pub const tls_record_plaintext_bytes_max: u32 = 16384;
/// RFC 8446 section 5.2: a protected record's body (content, type byte, up to 255 bytes of
/// padding, 16 bytes of tag). Longer is `record_overflow`.
pub const tls_record_ciphertext_bytes_max: u32 = 16384 + 256;
/// A record's header: type, legacy version, length.
pub const tls_record_header_bytes: u32 = 5;
/// Records the client seals under one key before it sends a `KeyUpdate`. The AES-GCM bound for
/// TLS 1.3 (RFC 8446 section 5.5) is about 2^24.5 records per key at a forgery probability of
/// 2^-57. The limit binds the sender: it is not applied to received records, since a peer
/// (OpenSSL, Go) may never send a KeyUpdate, or send one at a point of its own.
pub const tls_records_per_key_max: u64 = 1 << 24;
/// Records past `tls_records_per_key_max` a direction still seals: exactly the `KeyUpdate` that
/// replaces the key, and no data.
pub const tls_records_per_key_slack: u64 = 1;
/// Key updates one direction accepts in a connection; a peer that updates without end is refused.
pub const tls_key_updates_per_connection_max: u32 = 1 << 16;
/// One deadline for a whole TLS handshake, from the first byte sent to the client's last flight
/// (`tls_conn.zig` enforces it; a server that answers a byte a second still ends here).
pub const tls_handshake_timeout_ms: u32 = 10_000;
/// How long a refused connection gets to send its alert before it is dropped: a courtesy to the
/// server, never worth holding a slot for.
pub const tls_alert_flush_ms: u32 = 1_000;

comptime {
    assert(tls_record_plaintext_bytes_max == 16384);
    assert(tls_record_ciphertext_bytes_max == tls_record_plaintext_bytes_max + 256);
    assert(tls_record_ciphertext_bytes_max + tls_record_header_bytes < std.math.maxInt(u16));
    // The sequence number is a u64 that never wraps (RFC 8446 section 5.3).
    assert(tls_records_per_key_max + tls_records_per_key_slack < std.math.maxInt(u64));
    // Well below the AES-GCM limit, and the nonce space (2^64) is nowhere near.
    assert(tls_records_per_key_max <= 1 << 24);
    assert(tls_records_per_key_slack >= 1);
    assert(tls_key_updates_per_connection_max > 0);
}

// ---- TLS 1.3 client handshake (docs/briefs/mtls-client.md, slice 4) ---------------------------

/// One handshake message (type, three length bytes, body): the server flight is a chain of at
/// most `tls_chain_certificates_max` certificates of `x509_cert_bytes_max` each.
pub const tls_handshake_message_bytes_max: u32 = 4096;
/// The server's handshake messages together, EncryptedExtensions to Finished. This is also the
/// size of the client's reassembly buffer.
pub const tls_handshake_flight_bytes_max: u32 = 8192;
/// A server `Certificate` carries the leaf and, optionally, the CA certificate; no more.
pub const tls_chain_certificates_max: u32 = 2;
/// Plaintext `change_cipher_spec` records dropped per connection (RFC 8446 appendix D.4). A
/// server sends one, right after its ServerHello; a second is a fault.
pub const tls_change_cipher_spec_records_max: u32 = 1;
/// The longest name the client sends in `server_name` and checks the certificate against.
pub const tls_server_name_bytes_max: u32 = x509_dns_name_bytes_max;
/// The ClientHello record: fixed layout, so its size is a constant plus the server name.
pub const tls_client_hello_bytes_max: u32 =
    5 + 4 + 2 + 32 + (1 + 32) + (2 + 2) + (1 + 1) + tls_hello_extensions_bytes_max;
/// The longest `certificate_request_context` a server may send (a one-byte length): the client
/// echoes it in its Certificate.
pub const tls_request_context_bytes_max: u32 = 255;
/// The client's Certificate message: type and length, the echoed context, and at most
/// `tls_chain_certificates_max` certificates each with its three-byte length and empty
/// extensions (two bytes).
pub const tls_client_certificate_bytes_max: u32 = 4 + 1 + tls_request_context_bytes_max + 3 +
    tls_chain_certificates_max * (3 + x509_cert_bytes_max + 2);
/// What one protected handshake record adds to its message: header, inner type and tag.
pub const tls_record_overhead_bytes: u32 = tls_record_header_bytes + 1 + 16;
/// The client's CertificateVerify message: type and length, scheme, and a 64-byte signature.
pub const tls_client_verify_bytes: u32 = 4 + 2 + 2 + 64;
/// Bytes the client has ready to send after one step: the ClientHello, or a compatibility
/// change_cipher_spec and its whole last flight (Certificate, CertificateVerify, Finished, each
/// in a record of its own), or an alert, or a KeyUpdate. The caller drains it after every step.
pub const tls_output_bytes_max: u32 = (5 + 1) +
    (tls_client_certificate_bytes_max + tls_record_overhead_bytes) +
    (tls_client_verify_bytes + tls_record_overhead_bytes) + (4 + 32 + tls_record_overhead_bytes);
/// Extensions of the ClientHello: server_name, supported_groups, signature_algorithms (twice),
/// supported_versions and key_share, each with its four-byte header.
const tls_hello_extensions_bytes_max: u32 = 2 + (4 + 5 + tls_server_name_bytes_max) +
    (4 + 4) + (4 + 4) + (4 + 4) + (4 + 3) + (4 + 2 + 4 + 32);

comptime {
    assert(tls_handshake_message_bytes_max >= tls_chain_certificates_max * x509_cert_bytes_max);
    assert(tls_handshake_flight_bytes_max >= 2 * tls_handshake_message_bytes_max);
    assert(tls_handshake_flight_bytes_max < tls_record_plaintext_bytes_max);
    assert(tls_change_cipher_spec_records_max == 1);
    assert(tls_alert_flush_ms < tls_handshake_timeout_ms);
    assert(tls_handshake_timeout_ms < std.math.maxInt(i32)); // `poll` takes an i32.
    assert(tls_server_name_bytes_max <= 255);
    assert(tls_output_bytes_max >= tls_client_hello_bytes_max);
    assert(tls_output_bytes_max >= 6 + 5 + 4 + 32 + 1 + 16);
    // One message of the client's flight fits the handshake message bound.
    assert(tls_client_certificate_bytes_max <= tls_handshake_message_bytes_max);
    assert(tls_request_context_bytes_max < 256);
    assert(tls_output_bytes_max < tls_record_plaintext_bytes_max);
}

comptime {
    assert(peer_handshakes_max > peer_connections_max);
    assert(peer_handshakes_pending_per_source_max > 1);
    assert(peer_handshakes_pending_per_source_max * 2 <= peer_handshakes_max);
    assert(peer_connections_per_node_max > 0);
    assert(peer_connections_per_node_max < peer_connections_max);
    assert(fetch_busy_sleep_ms <= fetch_busy_sleep_max_ms);
    assert(fetch_busy_wait_ms < fetch_total_ms);
    assert(fetch_progress_ms < fetch_busy_wait_ms + fetch_request_timeout_ms);
    assert(peer_handshake_evict_min_ms < peer_handshake_ms);
    assert(peer_handshakes_per_source_max > 0);
    assert(peer_handshake_window_ms > 0);
    assert(peer_sources_max >= peer_handshakes_per_source_max);
    assert(peer_credential_ttl_ms < peer_credential_ttl_ms_max);
    assert(peer_record_bytes_max + 16 <= std.math.maxInt(u16));
    assert(peer_clock_skew_ms < peer_credential_ttl_ms / 2);
    // 256 names of the longest length, a newline each, fit the file bound.
    assert(peer_revoked_max * (node_name_bytes_max + 1) <= peer_file_bytes_max);
    assert(peer_join_timeout_ms < agent_io_timeout_ms);
}

comptime {
    assert(exit_ok == 0);
    assert(exit_internal == 70);
    assert(fleet_seen_per_day_max <= fleet_filed_max);
    assert(fleet_comments_per_failure_per_day_max > 0);
    assert(fleet_hold_seconds_default <= fleet_hold_seconds_max);
    assert(fleet_find_page_size * fleet_find_pages_max >= 100);
    assert(fleet_state_bytes_max >= fleet_token_bytes_max);
    assert(diag_command_bytes_max <= diag_field_bytes_max);
    assert(diag_summary_bytes_max < diag_wrap_columns);
    assert(diag_explanation_line_bytes_max < diag_wrap_columns);
    assert(diag_code_bytes_max == "ZBX-E0410".len);
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
    // An apply's transaction: service, history, a decision and the oldest generations it drops.
    assert(history_generations_max >= 1);
    assert(history_scan_max <= store_list_limit_max);
    assert(history_scan_max >= history_generations_max);
    assert(health_interval_ms_max <= health_verdict_ms_max);
    assert(rollout_grace_ms_max <= rollout_deadline_ms_max);
    assert(rollout_deadline_ms_max == job_deadline_ms_max);
    assert(service_name_bytes_max + 1 + 9 <= 63); // "<service>-<n>" fits a container name.
    assert(retention_batch_pairs * 2 <= store_txn_ops_max);
    assert(why_steps_max <= retention_pinned_max);
    assert(retention_scratch_bytes <= request_arena_bytes_max / 4);
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
    // docs/authority.md §3: fence_margin >= fence_stop + ttl * skew + kill latency.
    const skew_ms = lease_ttl_ms * clock_skew_per_mille / 1000;
    assert(fence_margin_ms >= fence_stop_ms + skew_ms + fence_kill_latency_ms);
    assert(fence_margin_ms < lease_ttl_ms);
    assert(decision_evidence_bytes_max < store_value_bytes_max);

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
    assert(summary_json_bytes_max <= store_value_bytes_max);
    assert(summary_request_bytes_max > agent_request_bytes_max);
    assert(summary_request_bytes_max <= request_arena_bytes_max / 8);
    assert(fetch_in_flight_per_peer_max <= fetch_in_flight_max);
    assert(fetch_peer_rate_bytes_per_s <= fetch_node_rate_bytes_per_s);
    assert(fetch_request_timeout_ms < fetch_peer_wait_ms);
    assert(fetch_peers_max <= 16); // A chunk's tried-peers set is a u16.
    assert(fetch_candidates_max >= fetch_peers_max);
    assert(fetch_candidates_max <= 255); // A peer's index is a u8.
    assert(fetch_list_peers_max <= fetch_peers_max);
    assert(fetch_total_ms > fetch_peer_wait_ms);
    assert(fetch_peer_poll_ms < fetch_peer_wait_ms);
    assert(fetch_backoff_base_ms > 0);
    assert(fetch_backoff_cap_ms >= fetch_backoff_base_ms);
}

// The Zigbox store adapter (`zigbox_images.zig`, C2 slice 8). All bounds, none a policy.

/// The scratch one Zigbox call reads or writes through: exactly Zigbox's `store_io_buffer_bytes`
/// (not exported), which `fs.read` asserts as a most and `chunk_hashes` as a least.
pub const zigbox_io_bytes: u32 = 256 * 1024;
/// The depth of the walk's explicit stack, in digests.
pub const zigbox_walk_stack_max: u32 = 1 << 12;
/// The chunks one object lists: exactly Zigbox's `store_chunks_max` (not exported), which
/// `chunk_hashes` asserts of the room it is given.
pub const zigbox_chunks_per_object_max: u32 = 4096;
/// The bytes the root listing's names may take.
pub const zigbox_roots_arena_bytes: u32 = 1 << 14;
/// The bytes of one image record (a peer's record is held to this before it is parsed).
pub const zigbox_record_bytes_max: u32 = 80 * 1024;
/// The objects an in-progress receive may hold claims on: as many as the walk's `entries_max`
/// (`zigbox_images.zig` asserts it), so every tree the walk accepts can be claimed.
pub const zigbox_claims_max: u32 = 1 << 16;
/// The bytes a tree record is read into.
pub const zigbox_tree_buffer_bytes: u32 = 4 << 20;

/// The most a validated pull record encodes to: the fixed fields (node, tree, four numbers, with
/// escapes) under 512 bytes, and `pull_peers_max` peers each in `peer_bytes` (a node name and a
/// byte count, about 110 bytes) and in `bad_peers` (a node name, 70). The agent endpoint refuses
/// a record that would encode larger, so this bounds what `/pulls/` holds.
pub const pull_record_bytes_max: u32 = 4 * 1024;

/// What reading one pull record costs `GET /v1/stats/pull`'s arena at most: its key and value
/// as the store copies them (SQLite and Postgres copy both; memory copies the page only), the
/// parsed record (strings and slices, never more than the value again) and the entry that holds
/// them. Measured (docs/decisions/2026-11-04-pull-stats-caps.md): about 5.0 KB for a 3,036-byte
/// record; this is for 4 KiB, and about twice that.
pub const pull_read_arena_bytes: u32 =
    store_key_bytes_max + 2 * pull_record_bytes_max + 1024;

/// `GET /v1/stats/pull` reads at most this many pull records, ascending by node, then says
/// `truncated`. Retention keeps up to `nodes_max` x `pulls_per_node_max` (6,400) records, which
/// the request arena cannot hold at the worst case; this is what it can (checked below).
pub const pulls_read_max: u32 = 500;

/// What `GET /v1/stats/pull` writes its answer into, taken at once: `api_list_limit_max` records
/// of at most `pull_record_bytes_max` each, and 4 KiB for the members around them. An arena frees
/// nothing, so a buffer that grew would leave all its smaller steps behind (about twice its final
/// size more); this one does not grow, because the agent endpoint refuses a larger record.
pub const pulls_response_bytes: u32 = api_list_limit_max * pull_record_bytes_max + 4 * 1024;

comptime {
    // One page is requested at a time and never more than the cap still allows plus one, so the
    // records the arena holds are the cap plus that one (read, then dropped unused).
    const records_held = pulls_read_max + 1;
    const sorted = 4 * pulls_read_max + 1024; // The order array and the pointers of the list.
    assert(records_held * pull_read_arena_bytes + pulls_response_bytes + sorted + 64 * 1024 <=
        request_arena_bytes_max / 2);
    assert(pull_record_bytes_max > 512 + pull_peers_max * (110 + 70));
    assert(pulls_read_max >= api_list_limit_max);
}

// ---- Jobs (B1, docs/briefs/b1.md "Bounds") -------------------------------------------------

/// Jobs not yet ended, cluster-wide: `/job-admission`'s `admitted` less `/job-endings`' `ended`.
/// A create over it is refused (ZC-E0132, 429).
pub const jobs_max: u32 = 512;
/// A node runs at most this many jobs at once; a further run waits `pending` (ZC-W0308).
pub const jobs_per_node_max: u32 = 64;
/// The runs list of one node (`GET /v1/agent/nodes/{node}/runs`): more is ZC-E0302, as for
/// replicas. One unpaged reply, so it stays under half a page (comptime below).
pub const agent_node_runs_max: u32 = jobs_per_node_max;
/// `/assigned/` holds the assignments of replicas and of runs, so every list of it is bounded by
/// both: a list with `replicas_max` alone fails (ZC-E0302) on a cluster with 300 replicas and 300
/// jobs (docs/briefs/b1-1.md).
pub const assigned_max: u32 = replicas_max + jobs_max;
/// The assignments of one node: its replicas and its runs. A node holds at most
/// `runtime_handles_max` of the two together (the scheduler refuses more), which this covers.
pub const agent_node_assigned_max: u32 = agent_node_replicas_max + agent_node_runs_max;
/// A run record, as encoded: the spec without the input. Enforced on the encoded JSON by
/// `records.encode` and `records.read`, not inferred from the raw sizes of its members: JSON
/// escaping turns one control byte into six.
pub const job_run_bytes_max: u32 = 16 * 1024;
/// `env` of a job; larger is refused (ZC-E0130). The input has a field of its own.
pub const job_env_bytes_max: u32 = 8 * 1024;
/// A job's input, as the container receives it: UTF-8 without NUL. It is stored as base64
/// (`JobInput.base64`), so the record is at most four thirds of this, never the sixfold of a JSON
/// string full of control characters, which would not fit `store_value_bytes_max`.
pub const job_input_bytes_max: u32 = 64 * 1024;
/// The body of `POST /v1/jobs` only; every other route keeps `api_request_bytes_max`. Six times
/// the input (every byte a control character escaped as `\u00XX`) plus 16 KiB for the other
/// fields, so every input that meets `job_input_bytes_max` is accepted however the client escapes
/// it (docs/decisions/2026-11-05-b1-job-input-wire-size-answer.md, option B).
pub const job_request_bytes_max: u32 = 6 * job_input_bytes_max + 16 * 1024;
pub const job_command_words_max: u32 = runtime_command_words_max;
/// The name of the variable a job's input is given in (`input_env`).
pub const job_input_env_bytes_max: u32 = 64;
/// Labels of a job: `runtime_labels_max` less `zcube.replica` and `zcube.job`.
pub const job_labels_max: u32 = runtime_labels_max - 2;
/// The bounds of a job's `limits`, those of Zigbox's runtime (`zigbox` `constants.zig`): a value
/// outside them would be refused when the run starts, long after the job was accepted.
/// Mirrors Zigbox's `limit_cpu_millis_min`.
pub const job_limit_cpu_millis_min: u32 = 10;
/// Mirrors Zigbox's `limit_cpu_millis_max`.
pub const job_limit_cpu_millis_max: u32 = 1_024_000;
/// Mirrors Zigbox's `limit_memory_bytes_min`.
pub const job_limit_memory_bytes_min: u64 = 4 * 1024 * 1024;
/// Mirrors Zigbox's `limit_memory_bytes_max`.
pub const job_limit_memory_bytes_max: u64 = 1 << 40;
/// Mirrors Zigbox's `limit_pids_min`.
pub const job_limit_pids_min: u32 = 1;
/// Mirrors Zigbox's `limit_pids_max`.
pub const job_limit_pids_max: u32 = 4_194_304;
/// A deadline counts from the start; a run not claimed by its `start_by_ms` (the same length from
/// creation) ends `failed deadline`. A job with no deadline is a service, so 0 is refused.
pub const job_deadline_ms_max: u64 = 24 * 60 * 60 * 1000;
pub const job_grace_ms_max: u32 = 60 * 1000;
/// `submit_by_ms` may be at most this far ahead of the server's clock at receipt, and a retained
/// ended job is never younger than `job_finished_age_ms_min` when deleted, so a retried POST
/// inside the window finds the job it created.
pub const job_submit_window_ms_max: u64 = 60 * 60 * 1000;
pub const job_finished_age_ms_max: u64 = 24 * 60 * 60 * 1000;
pub const job_finished_age_ms_min: u64 = 60 * 60 * 1000;
/// Jobs created within the admission window: the most that can be retained.
pub const job_admitted_window_max: u32 = 8192;
/// The window of `/job-admission`: the start backstop and the deadline (24 h each), retention
/// (24 h) and an hour for the submit window.
pub const job_admission_window_h: u32 = 73;
/// Longest run id: `<name>-job`.
pub const job_run_id_bytes_max: u32 = service_name_bytes_max + "-job".len;
/// Jobs the job controller reads and judges at a time. `/jobs/` holds up to
/// `job_admitted_window_max` records (ended jobs stay until retention), far more than one step's
/// arena holds with their runs, statuses and reports, so it reads a page of jobs with exactly the
/// records they need into an arena of its own, frees it, and goes on.
pub const job_controller_page_max: u32 = 16;
/// What one page of the job controller holds at most: per job the job, its run, its status and
/// its report (each a record of at most `job_run_bytes_max`), plus a page of decisions read to
/// tell whether it already decided (`decisions_per_subject_max` index entries of 512 bytes).
pub const job_controller_page_bytes_max: u64 = @as(u64, job_controller_page_max) *
    (4 * job_run_bytes_max) + @as(u64, decisions_per_subject_max) * 512 * job_controller_page_max;

comptime {
    assert(jobs_per_node_max <= runtime_handles_max);
    assert(jobs_max > 0);
    assert(agent_node_runs_max <= jobs_per_node_max);
    assert(assigned_max == replicas_max + jobs_max);
    assert(agent_node_assigned_max >= runtime_handles_max);
    // An assignment is a few hundred bytes (its reason is a sentence); the whole list is read into
    // the step's arena beside the other lists, so it keeps to a fraction of it.
    assert(assigned_max * 1024 <= request_arena_bytes_max / 8);
    // The reply is not paged: at most half a store page, as the replicas list is bounded by
    // `store_list_limit_max`.
    assert(agent_node_runs_max * job_run_bytes_max <= store_page_bytes_max / 2);
    assert(agent_node_runs_max <= store_list_limit_max);
    assert(job_run_bytes_max <= store_value_bytes_max);
    // `job_run_bytes_max` itself is enforced on the encoded record (records.encode and read), so
    // no relation between it and the raw sizes of env or command is asserted here.
    // The stored input is base64 (four thirds, rounded up to groups of four).
    assert((job_input_bytes_max + 2) / 3 * 4 < store_value_bytes_max);
    // The body that carries an input: the worst case is all control characters, six bytes each.
    assert(job_request_bytes_max >= 6 * job_input_bytes_max + 16 * 1024);
    assert(job_request_bytes_max > api_request_bytes_max);
    assert(job_request_bytes_max > http_head_bytes_max);
    // The body, its parse and the decoded input must sit in the request arena well within it.
    assert(job_request_bytes_max * 8 <= request_arena_bytes_max);
    assert(job_labels_max == 6);
    assert(job_command_words_max == runtime_command_words_max);
    // The run id is a container name (a hostname label), and `<service>-<n>` never equals it.
    assert(job_run_id_bytes_max <= 63);
    assert(job_deadline_ms_max <= x509_leaf_ttl_ms_max); // A leaf of a job outlives its deadline.
    assert(job_grace_ms_max <= job_deadline_ms_max);
    assert(job_submit_window_ms_max <= job_finished_age_ms_min);
    assert(job_finished_age_ms_min <= job_finished_age_ms_max);
    // 73 h: the start backstop, the deadline, retention and an hour's submit window.
    const window_ms = 2 * job_deadline_ms_max + job_finished_age_ms_max + job_submit_window_ms_max;
    assert(window_ms == @as(u64, job_admission_window_h) * 60 * 60 * 1000);
    assert(job_admitted_window_max >= jobs_max);
    assert(job_controller_page_max > 0);
    assert(job_controller_page_max <= store_list_limit_max);
    // The pages are freed one by one, so one page is what the job controller costs the step's
    // arena beyond the lists it reads once (nodes, their statuses and the assignments).
    assert(job_controller_page_bytes_max <= request_arena_bytes_max / 4);
    // One aggregate record: an hour's count per hour of the window, in JSON, in one value.
    // An entry is at most 49 bytes (`{"hour":N,"count":N},` with N up to 13 and 10 digits), and a
    // record holds at most `job_admission_window_h + 1` of them (`admission_valid`).
    assert((job_admission_window_h + 1) * 49 + 256 < store_value_bytes_max);
}

// ---- The relay (docs/briefs/b3.md, slice 2) ---------------------------------------------

/// Relays a server's configuration may name (`relays` in the ZON file).
pub const relays_max: u32 = 8;
/// A relay's name: a job names it, and it is a ZON field name.
pub const relay_name_bytes_max: u32 = 32;
/// A relay's upstream, `host:port`.
pub const relay_address_bytes_max: u32 = 256;
/// The environment variable that tells a job where its relay listens.
pub const relay_env_name = "ZCUBE_RELAY";
/// The port a job's relay listens on, on its own loopback (the real runtime; the fake runtime
/// listens on an ephemeral host port, because it makes no namespace).
pub const relay_port: u16 = 8080;
/// Open connections through one job's relay; a further one is closed and counted (ZC-W0701).
pub const relay_connections_max: u32 = 16;
/// Bytes copied in each direction of one connection; the connection ends at the bound (ZC-W0702).
pub const relay_connection_bytes_max: u64 = 1024 * 1024 * 1024;
/// A connection that carries no byte in either direction for this long is closed (ZC-W0702).
pub const relay_idle_ms: u32 = 300_000;
/// The upstream connect gives up after this long (ZC-E0704).
pub const relay_connect_timeout_ms: u32 = 10_000;
/// One direction's copy buffer.
pub const relay_buffer_bytes: u32 = 16 * 1024;
/// How often the relay's loop looks at its stop flag when nothing else wakes it.
pub const relay_poll_ms: u32 = 50;
/// The relay's own log in the container directory (`relay.log`): at most this many bytes.
pub const relay_log_bytes_max: u32 = 8 * 1024;

comptime {
    assert(relays_max > 0);
    assert(relay_name_bytes_max + relay_address_bytes_max < config_bytes_max);
    assert(relay_connections_max > 0);
    assert(relay_connect_timeout_ms < relay_idle_ms);
    assert(relay_poll_ms < relay_connect_timeout_ms);
    assert(relay_connection_bytes_max > relay_buffer_bytes);
    assert(relay_port >= 1024); // The job is unprivileged, and so is the listener.
}
