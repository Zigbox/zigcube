//! The test-only switches of the `sim-c1` negative tests (docs/authority.md §4, docs/core.md "The
//! cluster simulation"). Each is a constant that only a program's root file can switch on, by
//! declaring `pub const <name> = true;`: the roots that do are `src/sim_c1_teeth_*_main.zig`.
//! The `sim-c1-teeth*` steps compile all but `oldrule`, which only `sim-fencing-teeth` compiles.
//! Every shipped program, test and the WASM core has
//! another root, so for them each is false; `zcube_server.zig` and `zcube_agent.zig` assert that
//! at compile time.

const root = @import("root");

fn declared(comptime name: []const u8) bool {
    return @hasDecl(root, name) and @field(root, name);
}

/// The scheduler leaves `/allocations/<node>` out of a placement's compares (must break I6).
pub const skip_allocation_compare = declared("c1_teeth_skip_allocation_compare");
/// The scheduler leaves `/node-status/<node>` and `/nodes/<node>` out of a placement's compares
/// (with a node lost between planning and commit, must break I7).
pub const skip_readiness_compare = declared("c1_teeth_skip_readiness_compare");
/// Nodes' clocks run beyond the skew bound (must break I1b).
pub const skew_beyond_bound = declared("c1_teeth_skew_beyond_bound");
/// Agents freeze and containers ignore stops, and a wedged node is not excused (must break I1b).
pub const wedge = declared("c1_teeth_wedge");

/// A node registers again between a controller's read of its report and the decision's commit, as
/// if the controller did not compare the report's tenure (must break I3).
pub const stale_observation = declared("c1_teeth_stale_observation");

/// The scheduler ranks locality ahead of spread (C2 slice 5; must break the placement-order
/// invariant of `sim-cluster`).
pub const locality_before_spread = declared("c1_teeth_locality_before_spread");

/// The agent renews every `ttl / 3` again, and the shortest ttl is lifted to the margin
/// (`fencing.zig`; must break `fencing_settles`, run by hand at a ttl below 5,000 ms).
pub const old_renewal_rule = declared("c1_teeth_old_renewal_rule");

/// The agent starts a run whose container already exited (must break J2 and J7).
pub const job_restart = declared("c1_teeth_job_restart");
/// The agent starts a run before its claim commits (must break J7).
pub const job_claim = declared("c1_teeth_job_claim");
/// The scheduler places a run that has a `stop` (must break J5 and J7).
pub const job_double = declared("c1_teeth_job_double");
/// The job controller rewrites a terminal status (must break J3).
pub const job_rewrite = declared("c1_teeth_job_rewrite");
/// The agent ignores a run's `stop` (must break J6).
pub const job_cancel = declared("c1_teeth_job_cancel");
/// The agent ignores a run's deadline (must break J8).
pub const job_deadline = declared("c1_teeth_job_deadline");

/// The agent enforces a run's deadline `job_deadline_late_ms` late, its wake moved to match (must
/// break J8: the bound has no room for a deadline that is merely late).
pub const job_deadline_late = declared("c1_teeth_job_deadline_late");
pub const job_deadline_late_ms: u64 = if (job_deadline_late) 9_000 else 0;

/// The agent does not stop a run at its deadline from its own records and clock: only its pass,
/// which needs the server, or the fence does (must break J8: a node cut off from the server
/// overruns the deadline by up to the lease's ttl). The simulator turns partitions up, makes
/// them longer and draws more, shorter jobs under it, so that deadlines fall in the cuts.
pub const job_deadline_offline = declared("c1_teeth_job_deadline_offline");

/// Not a fault: the world of `job_deadline_offline` (long cuts, short deadlines) with the agent's
/// own enforcement left on, for the positive run `sim-c1-offline`. Not in `any`.
pub const offline_world = declared("c1_offline_world") or job_deadline_offline;

/// The job controller judges only the first `jobs_max` jobs of the admission window: each sweep
/// stops after that many and starts over, so a job past the 512th is never ended, even an
/// unplaceable one (must break J8's second clause past 512 runs; B2 slice 4, RB-N8). The
/// simulator makes more than 512 jobs in the burst world, with unplaceable ones (`strong`).
pub const job_evicted = declared("c1_teeth_job_evicted");

/// Not a fault: the world of `job_evicted` (burst world, `strong`) with the controller right, for
/// the positive run `sim-c1-worlds`. Not in `any`.
pub const evict_world = declared("c1_evict_world") or job_evicted;

/// Not a fault: a world of one node and bursts of short jobs, with the agent right, for the
/// regression `sim-c1-burst` (issue #198). One step starts dozens of runs there, which the
/// simulator once stamped as started at the wrong time (J8 failed on a correct agent). Not in
/// `any`.
pub const burst_world = declared("c1_burst_world") or evict_world;

/// The jobs watch drops the events of some endings (must break J4: a client that follows the watch
/// misses an ending it never hears of).
pub const job_gap = declared("c1_teeth_job_gap");

/// The agent reports a run it no longer holds under the assignment it was started under, and
/// commits without comparing that assignment (must break J9: a report of a retired or
/// superseded run is stored).
pub const job_stale = declared("c1_teeth_job_stale");

/// The agent's `running` job reports name an assignment that is not the stored one, so the store
/// refuses each one and the agent, which still holds the run unreported, makes it again on every
/// pass. Must break J10 (`reports_settle`): the bound on refused reports after the heal. (A
/// refusal of every report breaks J8 first, which hides the count: a run that never ends.)
pub const job_refused_loop = declared("c1_teeth_job_refused_loop");

/// The job controller never ends a run that no node claimed by its `start_by_ms` (must break J8's
/// second clause: "every run that is not claimed by `start_by_ms` ends failed"; B2 slice 4).
pub const job_unclaimed = declared("c1_teeth_job_unclaimed");

/// The agent that finds no start record of an assigned run (its state directory was lost) starts
/// the run from scratch, though its container exists and its `claimed` observation is stored (must
/// break J2: a run id is started at most once, ever; B2 slice 4, RB-S2 c).
pub const job_wipe = declared("c1_teeth_job_wipe");

/// The simulated runtime leaves a job's relay listener open when the container ends (must break R1:
/// a relay is open only while its run runs on that node; B3 slice 3). Relayed jobs are made only
/// in the `strong` world.
pub const relay_leak = declared("c1_teeth_relay_leak");

/// The agent builds a relayed job's spec without its relay (must break R3: a started job's spec
/// carries the relay the job asked for; B3 slice 3). Needs the `strong` world's relayed jobs.
pub const relay_dropped = declared("c1_teeth_relay_dropped");

/// The issuance rule (`job_cert.decide`) does not compare the ask's placement epoch with the
/// run's (must break R4: a certificate is issued only to the node that holds the run's claim, at
/// its epoch; B4 slice 3). The simulator's forged asks name stale epochs. Needs relayed jobs.
pub const job_cert_stale = declared("c1_teeth_job_cert_stale");

/// The issuance rule counts `workload_cert_slack_ms` twice in a certificate's `not_after` (must
/// break R5: no certificate outlives start + deadline + grace + slack; B4 slice 3).
pub const job_cert_long = declared("c1_teeth_job_cert_long");

/// The simulated runtime leaves a relayed run's connections open when the container ends (must
/// break R6: no relayed connection is open after its run's ending is reported; B4 slice 3).
pub const relay_conn_leak = declared("c1_teeth_relay_conn_leak");

/// The issuance rule (`job_cert.decide`) does not compare the ask's image digest with the one the
/// job pins (must break R4's image clause: a certificate names the job's pinned image; B4 slice 3
/// fixes). The simulator's forged asks name other images. Needs relayed jobs.
pub const job_cert_image = declared("c1_teeth_job_cert_image");

/// The simulated runtime does not close a relayed run's connections when its supervisor is told
/// to stop, only when the container ends after its grace (must break R7: connections end within
/// `relay_cancel_ms_max` of the stop; B4 slice 3 fixes). Needs relayed jobs.
pub const relay_stop_leak = declared("c1_teeth_relay_stop_leak");

/// The job start ledger holds `job_ledger_small_max` runs, not 4096 (must break J8: a full ledger
/// fails the run instead of leaving J2 and J8's second clause judging less than they claim).
pub const job_ledger_small = declared("c1_teeth_job_ledger_small");
pub const job_ledger_small_max: u32 = 16;

/// The simulated runtime reports every job container as made under an assignment newer than any
/// run's creation, as an agent that did not compare a leftover's epoch with the run's create
/// revision (`is_stale_epoch`, `agent_jobs.zig`) would read it: an agent that meets the stopped
/// container of an earlier job of the same name adopts it, and the new job ends with the old
/// job's exit and never starts (must break J11 in the reuse world; B2.1 slice 4, RB-N8). The
/// fault is in the runtime's listing, not in the agent, so that this slice leaves `agent_jobs.zig`
/// alone.
pub const job_reuse = declared("c1_teeth_job_reuse");

/// Not a fault: the reuse world, with the agent right, for the positive run `sim-c1-reuse`. Job
/// names are reused: a store-side retention jump (`Cluster.retention_jump`, which ticks no agent)
/// deletes ended jobs, and some creates then name a deleted job, so that a node's stopped
/// container of the earlier job meets the new one. Not in `any`.
pub const reuse_world = declared("c1_reuse_world") or job_reuse;

/// The scheduler's placement filter skips the `exclusive` rule, so a replica or a job of another
/// tenant can land on an exclusive node (must break P1: no assignment breaks a node's `exclusive`
/// or a job's `require`; B6 slice 2). Tenant labels exist only in the tenant world, which the
/// tooth switches on.
pub const placement_exclusive = declared("c1_teeth_placement_exclusive");

/// The replica and job controllers leave work on a node registered again with labels that refuse
/// it (must break P1's second part: a hold a relabel made refused is gone within the bound; B6
/// slice 2 fix). Needs the tenant world.
pub const relabel_kept = declared("c1_teeth_relabel_kept");

/// The teeth whose fault needs the `strong` world (state-directory wipes, unplaceable jobs, relayed
/// jobs).
pub const strong_world = job_unclaimed or job_wipe or evict_world or relay_leak or relay_dropped or
    job_cert_stale or job_cert_long or relay_conn_leak or job_cert_image or relay_stop_leak;

/// The agent starts every run its node's trust policy refuses: `trust_refusal` judges
/// nothing (must break J12: no run its node's policy refuses ever starts; B5 slice 3). Needs the
/// signed world (`Options.signed`).
pub const job_untrusted = declared("c1_teeth_job_untrusted");

/// The teeth whose fault needs the signed world.
pub const signed_world = job_untrusted;

/// The teeth whose fault needs the tenant world (`Options.tenants`).
pub const tenant_world = placement_exclusive or relabel_kept;

pub const any = old_renewal_rule or skip_allocation_compare or skip_readiness_compare or
    skew_beyond_bound or wedge or stale_observation or locality_before_spread or job_restart or
    job_claim or job_double or job_rewrite or job_cancel or job_deadline or job_deadline_late or
    job_deadline_offline or job_gap or job_stale or job_refused_loop or job_unclaimed or
    job_wipe or job_evicted or job_ledger_small or relay_leak or relay_dropped or job_reuse or
    job_cert_stale or job_cert_long or relay_conn_leak or job_cert_image or relay_stop_leak or
    job_untrusted or placement_exclusive or relabel_kept;

/// The runner a replay line names: the fault-on runner whose root switched a tooth on
/// (`sim_c1_teeth_<name>`, as `sim-c1-teeth-exe` installs it), the burst world's own runner, or
/// `sim_cluster`. Without it a failing tooth's replay ran the shipped code and passed.
pub const runner: []const u8 = blk: {
    // A tooth's root names its runner before a world's: `job_evicted` runs in the burst world.
    for (runners) |pair| {
        if (declared(pair[0])) break :blk pair[1];
    }
    if (burst_world) break :blk "sim_c1_burst";
    break :blk "sim_cluster";
};

/// Each tooth's root switch and the runner `sim-c1-teeth-exe` installs for it.
const runners = [_][2][]const u8{
    .{ "c1_teeth_skip_allocation_compare", "sim_c1_teeth_allocation" },
    .{ "c1_teeth_skip_readiness_compare", "sim_c1_teeth_readiness" },
    .{ "c1_teeth_skew_beyond_bound", "sim_c1_teeth_skew" },
    .{ "c1_teeth_wedge", "sim_c1_teeth_wedge" },
    .{ "c1_teeth_stale_observation", "sim_c1_teeth_stale" },
    .{ "c1_teeth_locality_before_spread", "sim_c1_teeth_locality" },
    .{ "c1_teeth_old_renewal_rule", "sim_c1_teeth_oldrule" },
    .{ "c1_teeth_job_restart", "sim_c1_teeth_job_restart" },
    .{ "c1_teeth_job_claim", "sim_c1_teeth_job_claim" },
    .{ "c1_teeth_job_double", "sim_c1_teeth_job_double" },
    .{ "c1_teeth_job_rewrite", "sim_c1_teeth_job_rewrite" },
    .{ "c1_teeth_job_cancel", "sim_c1_teeth_job_cancel" },
    .{ "c1_teeth_job_deadline", "sim_c1_teeth_job_deadline" },
    .{ "c1_teeth_job_deadline_late", "sim_c1_teeth_job_deadline_late" },
    .{ "c1_teeth_job_deadline_offline", "sim_c1_teeth_job_deadline_offline" },
    .{ "c1_teeth_job_gap", "sim_c1_teeth_job_gap" },
    .{ "c1_teeth_job_stale", "sim_c1_teeth_job_stale" },
    .{ "c1_teeth_job_refused_loop", "sim_c1_teeth_job_refused_loop" },
    .{ "c1_teeth_job_unclaimed", "sim_c1_teeth_job_unclaimed" },
    .{ "c1_teeth_job_wipe", "sim_c1_teeth_job_wipe" },
    .{ "c1_teeth_job_evicted", "sim_c1_teeth_job_evicted" },
    .{ "c1_teeth_job_ledger_small", "sim_c1_teeth_job_ledger_small" },
    .{ "c1_teeth_job_reuse", "sim_c1_teeth_job_reuse" },
    .{ "c1_teeth_relay_leak", "sim_c1_teeth_relay_leak" },
    .{ "c1_teeth_relay_dropped", "sim_c1_teeth_relay_dropped" },
    .{ "c1_teeth_job_cert_stale", "sim_c1_teeth_job_cert_stale" },
    .{ "c1_teeth_job_cert_long", "sim_c1_teeth_job_cert_long" },
    .{ "c1_teeth_relay_conn_leak", "sim_c1_teeth_relay_conn_leak" },
    .{ "c1_teeth_job_cert_image", "sim_c1_teeth_job_cert_image" },
    .{ "c1_teeth_relay_stop_leak", "sim_c1_teeth_relay_stop_leak" },
    .{ "c1_teeth_job_untrusted", "sim_c1_teeth_job_untrusted" },
    .{ "c1_teeth_placement_exclusive", "sim_c1_teeth_placement_exclusive" },
    .{ "c1_teeth_relabel_kept", "sim_c1_teeth_relabel_kept" },
};
