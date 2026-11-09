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

/// The teeth whose fault needs the `strong` world (state-directory wipes, unplaceable jobs).
pub const strong_world = job_unclaimed or job_wipe or evict_world;

pub const any = old_renewal_rule or skip_allocation_compare or skip_readiness_compare or
    skew_beyond_bound or wedge or stale_observation or locality_before_spread or job_restart or
    job_claim or job_double or job_rewrite or job_cancel or job_deadline or job_deadline_late or
    job_deadline_offline or job_gap or job_stale or job_refused_loop or job_unclaimed or
    job_wipe or job_evicted;
