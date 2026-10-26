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
}
