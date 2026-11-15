#!/bin/sh
# The simulation fleet's loop (ops/sim-fleet/README.md): follow the tip of main (and of each
# branch in SIM_FLEET_SOAK_REFS), rebuild a branch when it moves, run three producers over fresh
# seeds in parallel batches (`sim_cluster`, `sim_cluster --c1` and `sim_swarm`; the kinds
# `sim-cluster`, `sim-c1`, `sim-swarm`) on one branch's build per round, and hand each round
# (every batch, plus a record of each crashed seed) to `sim_fleet ingest`, once per kind. Every
# SIM_FLEET_CANARY_ONE_IN rounds a fourth worker runs the teeth canary, a fault-on runner that
# must fail. Settings come from the environment (the unit reads /etc/sim-fleet/fleet.env). The
# token is a file; this script never prints it. So is the heartbeat URL (heartbeat): it is
# read only by `sim_fleet heartbeat`, from its file, and never printed or put on a command line.
#
# The checkout this script runs from (the service checkout) never moves: each branch is built in
# a git worktree of its own ($STATE/refs/<id>/src, build_commit), and a soaked commit contributes
# only its producers. The reporter (`sim_fleet`: ingest, heartbeat, token check, state file) is
# always the fleet's own, built at start from the service checkout (build_reporter), so a commit
# from before a reporter change soaks as well as main; to update the reporter, redeploy.
set -eu

main() {
    : "${SIM_FLEET_HOME:=/var/lib/sim-fleet}"
    : "${SIM_FLEET_DRY_RUN:=}"
    # A dry run gets a checkout and a state of its own: it must not touch the service's.
    if [ -n "$SIM_FLEET_DRY_RUN" ]; then
        : "${SIM_FLEET_REPO_DIR:=$SIM_FLEET_HOME/dry/zigcube}"
        : "${SIM_FLEET_STATE_DIR:=$SIM_FLEET_HOME/dry/state}"
    else
        : "${SIM_FLEET_REPO_DIR:=$SIM_FLEET_HOME/zigcube}"
        : "${SIM_FLEET_STATE_DIR:=$SIM_FLEET_HOME/state}"
    fi
    : "${SIM_FLEET_REMOTE:=https://github.com/Zigbox/zigcube}"
    : "${SIM_FLEET_GH_REPO:=Zigbox/zigcube}"
    : "${SIM_FLEET_BRANCH:=main}"
    # Branches soaked besides SIM_FLEET_BRANCH (a release branch before its tag), space-separated,
    # at most 4. Each is built and run on its own; the rounds take the branches in turn (pick_ref).
    : "${SIM_FLEET_SOAK_REFS:=}"
    # `auto` draws each run's size and shape from its seed, and the profile (which faults are on)
    # too: the fleet exists for the variety (docs/core.md, "Profiles and shapes"). A number fixes
    # the operations (the nodes, ttl and replicas stay the seed's own old defaults); a profile
    # name (`mixed`, `partitions`, ...) fixes the profile. An fleet.env that sets SIM_FLEET_OPS=100
    # from before the draw keeps the old fixed size.
    : "${SIM_FLEET_OPS:=auto}"
    : "${SIM_FLEET_PROFILE:=auto}"
    : "${SIM_FLEET_BATCH:=100}"
    # Seeds per batch by kind; the cluster kinds fall back to SIM_FLEET_BATCH. The swarm's default
    # is 50000 and ignores SIM_FLEET_BATCH, because an installed fleet.env already sets that to
    # 100 (setup.sh never overwrites it) and the swarm worker would idle. A swarm seed takes
    # ~1.5 ms to a cluster seed's ~1.1 s (measured 2026-11-04, ReleaseSafe, 100 operations), so
    # 50000 keep its core about as busy as 100 cluster seeds keep theirs.
    : "${SIM_FLEET_BATCH_CLUSTER:=$SIM_FLEET_BATCH}"
    : "${SIM_FLEET_BATCH_C1:=$SIM_FLEET_BATCH}"
    : "${SIM_FLEET_BATCH_SWARM:=50000}"
    # Parallel workers per kind (one core each): 1 + 1 + 1 leaves a core of a 4 vCPU host for the
    # reporter, git and builds. A kind set to 0 is not run.
    : "${SIM_FLEET_WORKERS_CLUSTER:=1}"
    : "${SIM_FLEET_WORKERS_C1:=1}"
    : "${SIM_FLEET_WORKERS_SWARM:=1}"
    : "${SIM_FLEET_CACHE_MB:=8192}"
    # The teeth canary: 1 round in this many also runs the next fault-on runner of the cycle
    # (canary_pick); 0 never does, 1 every round. A miss is filed as an issue.
    : "${SIM_FLEET_CANARY_ONE_IN:=50}"
    # A canary GitHub held back, or the host kept from running, runs again next round, this many
    # tries in a row at most (canary_retry).
    : "${SIM_FLEET_CANARY_TRIES_MAX:=5}"
    : "${SIM_FLEET_TRACKER:=}"
    # Deadlines, in seconds: nothing the loop waits on may hang it.
    : "${SIM_FLEET_GIT_TIMEOUT:=300}"
    : "${SIM_FLEET_BUILD_TIMEOUT:=3600}"
    : "${SIM_FLEET_BATCH_TIMEOUT:=3600}"
    : "${SIM_FLEET_REPORT_TIMEOUT:=600}"
    # 0: run forever (the service). N: stop after N rounds (a dry run, a test).
    : "${SIM_FLEET_ROUNDS:=0}"
    : "${SIM_FLEET_IDLE_SECONDS:=60}"
    case "$SIM_FLEET_CANARY_ONE_IN" in
    '' | *[!0-9]*)
        log "SIM_FLEET_CANARY_ONE_IN is '$SIM_FLEET_CANARY_ONE_IN': it must be a number (0: off)"
        exit 2
        ;;
    esac
    case "$SIM_FLEET_CANARY_TRIES_MAX" in
    '' | *[!0-9]* | 0)
        log "SIM_FLEET_CANARY_TRIES_MAX is '$SIM_FLEET_CANARY_TRIES_MAX': it must be 1 or more"
        exit 2
        ;;
    esac
    if [ -n "${SIM_FLEET_WORKERS:-}" ]; then
        log "SIM_FLEET_WORKERS is ignored: set SIM_FLEET_WORKERS_CLUSTER, _C1 and _SWARM"
    fi
    token_file="${SIM_FLEET_TOKEN_FILE:-${CREDENTIALS_DIRECTORY:+$CREDENTIALS_DIRECTORY/token}}"
    if [ -z "$SIM_FLEET_DRY_RUN" ] && [ -z "$token_file" ]; then
        log "no token: set SIM_FLEET_TOKEN_FILE, run under the unit, or set SIM_FLEET_DRY_RUN=1"
        exit 2
    fi
    REFS=""
    for name in $SIM_FLEET_BRANCH $SIM_FLEET_SOAK_REFS; do
        if ! ref_valid "$name"; then
            log "the branch name '$name' is not one run.sh soaks ([A-Za-z0-9._/-], no '..'," \
                "no leading '-', at most 128 bytes)"
            exit 2
        fi
        case " $REFS " in *" $name "*) continue ;; esac
        REFS="${REFS:+$REFS }$name"
    done
    set -- $REFS
    if [ "$#" -gt 5 ]; then
        log "SIM_FLEET_SOAK_REFS names $(($# - 1)) branches besides $SIM_FLEET_BRANCH: at most 4"
        exit 2
    fi
    heartbeat_file=${SIM_FLEET_HEARTBEAT_FILE:-}
    if [ -z "$heartbeat_file" ] && [ -n "${CREDENTIALS_DIRECTORY:-}" ]; then
        heartbeat_file=$CREDENTIALS_DIRECTORY/heartbeat-url
    fi
    if [ -z "$heartbeat_file" ] || [ ! -s "$heartbeat_file" ]; then
        log "no heartbeat URL (${heartbeat_file:-no file}): no heartbeat is sent"
        heartbeat_file=""
    fi
    STATE=$SIM_FLEET_STATE_DIR
    KINDS="sim-cluster sim-c1 sim-swarm"
    mkdir -p "$STATE/bin" "$STATE/crashes"
    # One loop per state directory: two would race on the state file and the checkout.
    exec 9>"$STATE/lock"
    if ! flock -n 9; then
        log "another run.sh holds $STATE/lock; exiting"
        exit 2
    fi
    if [ ! -d "$SIM_FLEET_REPO_DIR/.git" ]; then
        mkdir -p "$(dirname "$SIM_FLEET_REPO_DIR")"
        timeout "$SIM_FLEET_GIT_TIMEOUT" \
            git clone --quiet "$SIM_FLEET_REMOTE" "$SIM_FLEET_REPO_DIR"
    fi
    cd "$SIM_FLEET_REPO_DIR"
    if ! build_reporter; then exit 2; fi
    rounds=0
    while [ "$SIM_FLEET_ROUNDS" -eq 0 ] || [ "$rounds" -lt "$SIM_FLEET_ROUNDS" ]; do
        rounds=$((rounds + 1))
        follow_refs
        pick_ref
        if [ -z "$built" ]; then
            log "nothing built yet; waiting"
            sleep "$SIM_FLEET_IDLE_SECONDS"
            continue
        fi
        run_round
    done
}

log() {
    printf '%s sim-fleet: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# Builds the fleet's own `sim_fleet` from the service checkout, as it is, into $STATE/fleet, and
# sets reporter. Every ingest and heartbeat uses it, whatever commit a round runs. A failure is
# logged and the service stops (exit 2; the unit restarts it).
build_reporter() {
    reporter=$STATE/fleet/bin/sim_fleet
    log "building the fleet's own sim_fleet at $(git rev-parse --short HEAD) (the service checkout)"
    if timeout "$SIM_FLEET_BUILD_TIMEOUT" zig build -Doptimize=ReleaseSafe \
        --cache-dir "$STATE/zig-cache" --prefix "$STATE/fleet" sim-fleet-exe \
        >"$STATE/build-fleet.log" 2>&1 && [ -x "$reporter" ]; then
        return 0
    fi
    log "the fleet's own sim_fleet did not build (see $STATE/build-fleet.log); stopping"
    return 1
}

# A branch name run.sh accepts: the same rule as `sim_fleet ingest --ref`.
ref_valid() {
    case "$1" in
    '' | -* | *..* | *[!A-Za-z0-9._/-]*) return 1 ;;
    esac
    [ "${#1}" -le 128 ]
}

# The directory of branch $1's state: `built` (the commit in use), `broken` (the tip that failed
# to build) and `gone` (the branch was deleted). SIM_FLEET_BRANCH keeps the top of the state
# directory, as before soak branches, so a rollback of run.sh finds its `built` there.
ref_dir() {
    if [ "$1" = "$SIM_FLEET_BRANCH" ]; then
        echo "$STATE"
    else
        echo "$STATE/refs/$(ref_id "$1")"
    fi
}

ref_id() {
    printf '%s' "$1" | sha256sum | cut -c1-16
}

# The worktree branch $1 is built in (every branch, SIM_FLEET_BRANCH too).
ref_src() {
    echo "$STATE/refs/$(ref_id "$1")/src"
}

# Whether commit $1 has a complete build: build_commit's mark, or a build of an earlier run.sh
# (it built sim_swarm last).
commit_built() {
    [ -e "$STATE/bin/$1/complete" ] || [ -x "$STATE/bin/$1/bin/sim_swarm" ]
}

# The commit branch $1 runs on: its `built`, if that commit's binaries are still there.
ref_built() {
    b=$(cat "$(ref_dir "$1")/built" 2>/dev/null || true)
    if [ -n "$b" ] && commit_built "$b"; then echo "$b"; fi
}

# Removes branch $1's worktree, if it has one.
drop_src() {
    src=$(ref_src "$1")
    if [ -e "$src" ]; then
        git worktree remove --force "$src" >/dev/null 2>&1 || rm -rf "$src"
        git worktree prune
    fi
}

# Writes $2 to file $1 at once.
put() {
    echo "$2" >"$1.new"
    mv "$1.new" "$1"
}

# Looks up every branch's tip (one `git ls-remote`) and follows each (follow_ref). A branch the
# remote no longer has is dropped: one log line, its build forgotten, and nothing run on it until
# it comes back. A lookup that fails keeps everything as it was.
follow_refs() {
    if ! timeout "$SIM_FLEET_GIT_TIMEOUT" git ls-remote --heads origin >"$STATE/heads.new"; then
        log "git ls-remote failed or timed out; keeping every branch's build"
        return 0
    fi
    # An answer with no branch at all is not taken as every branch deleted.
    if [ ! -s "$STATE/heads.new" ]; then
        log "git ls-remote listed no branch; keeping every branch's build"
        return 0
    fi
    for name in $REFS; do
        dir=$(ref_dir "$name")
        mkdir -p "$dir"
        head=$(awk -v r="refs/heads/$name" '$2 == r { print $1 }' "$STATE/heads.new")
        if [ -z "$head" ]; then
            if [ ! -e "$dir/gone" ]; then
                log "branch $name is gone from the remote; dropped until it comes back"
                : >"$dir/gone"
                rm -f "$dir/built" "$dir/broken"
                drop_src "$name"
            fi
            continue
        fi
        if [ -e "$dir/gone" ]; then
            log "branch $name is back"
            rm -f "$dir/gone"
        fi
        follow_ref "$name" "$head"
    done
    prune_bin
}

# Branch $1's tip is $2. If that commit is neither in use nor known to fail to build, fetches and
# builds it into a directory of its own (one already built for another branch is shared) and
# switches the branch to it only once the build succeeded. A build that fails leaves the last good
# binaries in use and is logged once.
follow_ref() {
    dir=$(ref_dir "$1")
    built=$(ref_built "$1")
    broken=$(cat "$dir/broken" 2>/dev/null || true)
    if [ "$2" = "$built" ] || [ "$2" = "$broken" ]; then return 0; fi
    if commit_built "$2"; then
        put "$dir/built" "$2"
        log "$1 is at $2, already built"
        return 0
    fi
    if ! timeout "$SIM_FLEET_GIT_TIMEOUT" git fetch --quiet origin "refs/heads/$1"; then
        log "git fetch of $1 failed or timed out; keeping ${built:-nothing}"
        return 0
    fi
    head=$(git rev-parse FETCH_HEAD)
    if [ "$head" = "$built" ] || [ "$head" = "$broken" ]; then return 0; fi
    log "building $head ($1)"
    if build_commit "$head" "$1"; then
        put "$dir/built" "$head"
        log "built $head ($1)"
    else
        put "$dir/broken" "$head"
        log "build of $head ($1) FAILED or timed out (see $STATE/build.log);" \
            "$1 still runs ${built:-nothing}"
    fi
}

# Builds commit $1, the tip of branch $2, into $STATE/bin/$1, in the branch's own worktree
# (ref_src); the service checkout is never checked out or detached. Only the producers the
# commit has are built (sim-cluster-exe, sim-swarm-exe, sim-canary-exe, as `zig build -l` lists
# them; it must have one of the first two): never its sim_fleet, since the fleet's own reporter
# runs every round (build_reporter). Exit code 0 when it built.
build_commit() {
    prune_cache
    src=$(ref_src "$2")
    rm -rf "$STATE/bin/$1"
    if ! worktree_at "$src" "$1" >"$STATE/build.log" 2>&1; then return 1; fi
    steps=$(cd "$src" && timeout "$SIM_FLEET_BUILD_TIMEOUT" zig build -l \
        --cache-dir "$STATE/zig-cache" 2>>"$STATE/build.log" |
        awk '$1 == "sim-cluster-exe" || $1 == "sim-swarm-exe" || $1 == "sim-canary-exe" {
            printf "%s ", $1 }')
    case " $steps" in
    *" sim-cluster-exe "* | *" sim-swarm-exe "*) ;;
    *)
        echo "$1 lists neither sim-cluster-exe nor sim-swarm-exe" >>"$STATE/build.log"
        return 1
        ;;
    esac
    # shellcheck disable=SC2086 # $steps is a list of step names.
    if (cd "$src" && timeout "$SIM_FLEET_BUILD_TIMEOUT" zig build -Doptimize=ReleaseSafe \
        --cache-dir "$STATE/zig-cache" --prefix "$STATE/bin/$1" $steps) \
        >>"$STATE/build.log" 2>&1; then
        : >"$STATE/bin/$1/complete"
        return 0
    fi
    rm -rf "$STATE/bin/$1"
    return 1
}

# Checks out commit $1 in worktree $2 of the service checkout's repository, making the worktree
# when it is missing or broken.
worktree_at() {
    if [ -e "$1/.git" ] &&
        timeout "$SIM_FLEET_GIT_TIMEOUT" git -C "$1" checkout --quiet --detach --force "$2"; then
        return 0
    fi
    git worktree remove --force "$1" 2>/dev/null || true
    rm -rf "$1"
    git worktree prune
    mkdir -p "$(dirname "$1")"
    timeout "$SIM_FLEET_GIT_TIMEOUT" git worktree add --quiet --detach "$1" "$2"
}

# Picks the branch this round runs on: the branches with a build take turns, one round each, in
# the order of $REFS (SIM_FLEET_BRANCH first), the place kept in $STATE/ref-next. Every worker of
# the round runs on that branch's commit. Sets ref and built (empty: nothing built yet).
pick_ref() {
    ref=""
    built=""
    n=0
    for name in $REFS; do
        if [ -n "$(ref_built "$name")" ]; then n=$((n + 1)); fi
    done
    if [ "$n" -eq 0 ]; then return 0; fi
    next=$(cat "$STATE/ref-next" 2>/dev/null || echo 0)
    case "$next" in '' | *[!0-9]*) next=0 ;; esac
    want=$((next % n))
    i=0
    for name in $REFS; do
        b=$(ref_built "$name")
        if [ -z "$b" ]; then continue; fi
        if [ "$i" -eq "$want" ]; then
            ref=$name
            built=$b
        fi
        i=$((i + 1))
    done
    put "$STATE/ref-next" "$((want + 1))"
}

# The binaries of every commit no branch uses, and the worktree of every branch not soaked.
prune_bin() {
    keep=" "
    ids=" "
    for name in $REFS; do
        keep="$keep$(cat "$(ref_dir "$name")/built" 2>/dev/null || true) "
        ids="$ids$(ref_id "$name") "
    done
    for dir in "$STATE"/bin/*; do
        [ -d "$dir" ] || continue
        case "$keep" in *" $(basename "$dir") "*) ;; *) rm -rf "$dir" ;; esac
    done
    for src in "$STATE"/refs/*/src; do
        [ -d "$src" ] || continue
        case "$ids" in
        *" $(basename "$(dirname "$src")") "*) ;;
        *)
            git worktree remove --force "$src" >/dev/null 2>&1 || rm -rf "$src"
            git worktree prune
            ;;
        esac
    done
}

# The build caches grow with every commit; past the limit they are emptied and the next build
# starts cold (and fetches its packages again). The service checkout's own `.zig-cache` is
# setup.sh's (and an earlier run.sh's); its zig-pkg stays, for build_reporter.
prune_cache() {
    used=$(du -smc "$STATE/zig-cache" "$STATE"/refs/*/src/zig-pkg .zig-cache \
        "$HOME/.cache/zig" 2>/dev/null | tail -n1 | cut -f1)
    if [ "${used:-0}" -gt "$SIM_FLEET_CACHE_MB" ]; then
        log "build caches are ${used} MB (limit $SIM_FLEET_CACHE_MB); emptying them"
        rm -rf "$STATE/zig-cache" "$STATE"/refs/*/src/zig-pkg .zig-cache "$HOME/.cache/zig"
    fi
}

# The simulator kind whose output kind $1 prints: itself, or for the canary its runner's
# (canary_pick sets canary_kind).
kind_sim() {
    if [ "$1" = sim-canary ]; then echo "$canary_kind"; else echo "$1"; fi
}

# The executable that produces kind $1, and the flags that make it that kind. The canary runs
# with the fleet's widest settings whatever SIM_FLEET_OPS and SIM_FLEET_PROFILE say.
kind_exe() {
    case "$1" in
    sim-canary) echo "$canary_runner" ;;
    sim-swarm) echo sim_swarm ;;
    *) echo sim_cluster ;;
    esac
}

kind_flags() {
    profile=$SIM_FLEET_PROFILE
    if [ "$1" = sim-canary ]; then profile=auto; fi
    if [ "$1" = sim-canary ] && [ -n "$canary_ops" ]; then
        # A fixed range runs the world its tooth was found in: the runner's default profile.
        echo "--c1"
        return 0
    fi
    # The sim-c1 workers run B5's trust world (`--signed`, J12); a canary keeps the world its
    # tooth was measured in.
    case "$(kind_sim "$1")" in
    sim-c1) if [ "$1" = sim-c1 ]; then
        echo "--c1 --signed --profile=$profile"
    else echo "--c1 --profile=$profile"; fi ;;
    *) echo "--profile=$profile" ;;
    esac
}

# `--shrink` for every kind but the canary: its fault is on, so a failure is the point and has
# nothing to shrink (owner decision, 2026-11-05).
kind_shrink() {
    if [ "$1" = sim-canary ]; then echo ""; else echo --shrink; fi
}

kind_ops() {
    if [ "$1" = sim-canary ] && [ -n "$canary_ops" ]; then
        echo "$canary_ops"
    elif [ "$1" = sim-canary ]; then echo auto; else echo "$SIM_FLEET_OPS"; fi
}

# The summary line's operations, as the producers print it: `N operations`, or for a drawn size
# `drawn operations` (src/sim_fleet_issue.zig reads both).
ops_phrase() {
    ops=$(kind_ops "$1")
    if [ "$ops" = auto ]; then echo "drawn operations"; else echo "$ops operations"; fi
}

# The summary line's prefix.
kind_prefix() {
    case "$(kind_sim "$1")" in
    sim-swarm) echo sim-swarm ;;
    sim-c1) echo "sim-cluster --c1" ;;
    *) echo sim-cluster ;;
    esac
}

# Seeds per batch of kind $1 (defaults above; the canary's from its manifest).
kind_batch() {
    case "$1" in
    sim-canary) echo "$canary_seeds" ;;
    sim-cluster) echo "$SIM_FLEET_BATCH_CLUSTER" ;;
    sim-c1) echo "$SIM_FLEET_BATCH_C1" ;;
    *) echo "$SIM_FLEET_BATCH_SWARM" ;;
    esac
}

# The flag that traces each seed's replay line and step to stderr: the cluster runners have it,
# `sim_swarm` (and its fault-on runner) not, so a swarm crash is in the step "run".
kind_trace() {
    if [ "$(kind_sim "$1")" = sim-swarm ]; then echo ""; else echo --trace-steps; fi
}

kind_workers() {
    case "$1" in
    sim-cluster) echo "$SIM_FLEET_WORKERS_CLUSTER" ;;
    sim-c1) echo "$SIM_FLEET_WORKERS_C1" ;;
    *) echo "$SIM_FLEET_WORKERS_SWARM" ;;
    esac
}

# One round: for each kind, its workers run its producer over fresh seed ranges in parallel (one
# core each; the default 1 + 1 + 1 leaves a core of a 4 vCPU host for the reporter, git and the
# build), then one `sim_fleet ingest --kind K` per kind of what the round found. A producer exits
# 1 when seeds failed (that is the point); a run killed by a signal crashed, and its range is
# replayed seed by seed. Workers are numbered across kinds; `$round/kind-W` names worker W's. A
# kind whose producer the commit does not have is skipped (kind_built). The round is clean, and
# the heartbeat sent, only when some kind's seeds were counted and every ingest succeeded.
run_round() {
    bin="$STATE/bin/$built/bin"
    round_started=$(date +%s)
    round_clean=1
    seeds_counted=""
    round="$STATE/round"
    rm -rf "$round"
    mkdir -p "$round"
    canary_pick
    workers=0
    for kind in $KINDS; do
        if ! kind_built "$kind"; then continue; fi
        n=$(kind_workers "$kind")
        i=0
        while [ "$i" -lt "$n" ]; do
            start_worker "$workers" "$kind"
            workers=$((workers + 1))
            i=$((i + 1))
        done
    done
    if [ -n "$canary_runner" ]; then
        canary_worker=$workers
        start_worker "$workers" sim-canary
        workers=$((workers + 1))
    fi
    wait
    for kind in $KINDS; do
        : >"$round/all-$kind"
        w=0
        while [ "$w" -lt "$workers" ]; do
            if [ "$(cat "$round/kind-$w")" = "$kind" ]; then
                collect "$w" "$kind" >>"$round/all-$kind"
            fi
            w=$((w + 1))
        done
        if [ -s "$round/all-$kind" ]; then
            ic=0
            ingest "$kind" "$round/all-$kind" || ic=$?
            # 3: counted, but GitHub kept part of it from being written (ingest).
            if [ "$ic" -eq 0 ] || [ "$ic" -eq 3 ]; then seeds_counted=1; fi
            if [ "$ic" -ne 0 ]; then round_clean=""; fi
        fi
    done
    if [ -n "$canary_runner" ]; then canary_report "$canary_worker"; fi
    if [ -z "$seeds_counted" ]; then
        log "no seed of this round was counted at $built: not a clean round"
        round_clean=""
    fi
    heartbeat
}

# Whether this round's commit has kind $1's producer; the first round without it says so once.
kind_built() {
    if [ -x "$bin/$(kind_exe "$1")" ]; then return 0; fi
    if [ ! -e "$STATE/bin/$built/skipped-$1" ]; then
        log "$built has no $(kind_exe "$1"): $1 is skipped on it"
        : >"$STATE/bin/$built/skipped-$1"
    fi
    return 1
}

# After the round: `sim_fleet heartbeat` checks the token (its expiry is kept in the state and
# a warning logged under 14 days; a refusal logged) and, after a clean round (run_round) when
# the heartbeat file holds a URL, sends one GET to it. sim_fleet logs the outcome; the URL
# stays in its file. A dry run checks no token.
heartbeat() {
    set -- heartbeat
    if [ -z "$SIM_FLEET_DRY_RUN" ]; then
        set -- "$@" --repo "$SIM_FLEET_GH_REPO" --token-file "$token_file" \
            --state "$STATE/state.txt"
    elif [ -z "${heartbeat_file:-}" ]; then
        return 0
    fi
    if [ -n "${heartbeat_file:-}" ]; then set -- "$@" --url-file "$heartbeat_file"; fi
    if [ -n "${round_clean:-}" ]; then set -- "$@" --clean; fi
    hc=0
    timeout "$SIM_FLEET_REPORT_TIMEOUT" "$reporter" "$@" || hc=$?
    if [ "$hc" -ne 0 ]; then log "sim_fleet heartbeat exited $hc"; fi
}

# The teeth canary (docs/briefs/c3-sim-fleet.md, item 3): the fleet's own proof that it still
# detects. Every SIM_FLEET_CANARY_ONE_IN rounds, the next runner of the manifest
# `sim-canary-exe` installs (generated from build.zig's `c1_teeth_roots`: `<runner> <kind>
# <seeds> <symptom>`, `-` for any) runs as one more worker of the round, like a worker of its
# kind (fresh seeds, drawn operations and profile; no --shrink, since a miss has nothing to
# shrink and the owner decided 2026-11-05 that a caught fault need not be), and its output goes
# to `sim_fleet ingest --canary`, which files a miss, a wrong symptom or a crash
# (canary_report). The cycle's place is kept in $STATE/canary-next and $STATE/canary-due; a
# canary that GitHub held back or that the host kept from running runs again next round, at
# most SIM_FLEET_CANARY_TRIES_MAX times in a row (canary_retry). Sets canary_runner (empty: no
# canary this round), canary_kind, canary_seeds and canary_symptom.
canary_pick() {
    canary_runner=""
    canary_first=""
    canary_ops=""
    if [ "$SIM_FLEET_CANARY_ONE_IN" -eq 0 ]; then return 0; fi
    due=$(number_in "$STATE/canary-due")
    due=$((due + 1))
    if [ "$due" -lt "$SIM_FLEET_CANARY_ONE_IN" ]; then
        echo "$due" >"$STATE/canary-due"
        return 0
    fi
    manifest="$STATE/bin/$built/share/sim-fleet/canaries.txt"
    count=$(grep -c '^[a-z]' "$manifest" 2>/dev/null || true)
    if [ "${count:-0}" -eq 0 ]; then
        log "no canary manifest at $built ($manifest); no canary until the next cycle"
        echo 0 >"$STATE/canary-due"
        return 0
    fi
    next=$(($(number_in "$STATE/canary-next") % count))
    line=$(grep '^[a-z]' "$manifest" | sed -n "$((next + 1))p")
    canary_runner=${line%% *}
    rest=${line#* }
    canary_kind=${rest%% *}
    rest=${rest#* }
    canary_seeds=${rest%% *}
    # `FIRST+COUNT@OPS`: a sparse tooth's fixed range (build.zig, `canary_first`).
    canary_first=""
    canary_ops=""
    case "$canary_seeds" in
    *+*@*)
        canary_ops=${canary_seeds#*@}
        canary_first=${canary_seeds%%+*}
        canary_seeds=${canary_seeds#*+}
        canary_seeds=${canary_seeds%%@*}
        ;;
    esac
    canary_symptom=${rest#* }
    if [ "$canary_symptom" = - ]; then canary_symptom=""; fi
    if [ ! -x "$bin/$canary_runner" ]; then
        log "canary $canary_runner is in the manifest but not built at $built; skipped"
        canary_runner=""
        canary_done
    fi
}

# The number in file $1, or 0 if it has none.
number_in() {
    value=$(cat "$1" 2>/dev/null || true)
    case "$value" in '' | *[!0-9]*) echo 0 ;; *) echo "$value" ;; esac
}

# The cycle moves on: the next canary runs SIM_FLEET_CANARY_ONE_IN rounds from now.
canary_done() {
    echo $(($(number_in "$STATE/canary-next") + 1)) >"$STATE/canary-next"
    echo 0 >"$STATE/canary-due"
    echo 0 >"$STATE/canary-tries"
}

# The canary could not be filed or did not run, for a reason that may pass (GitHub asked to wait,
# the host was short of memory): it runs again next round, but only $SIM_FLEET_CANARY_TRIES_MAX
# times in a row, then the cycle moves on and the log says so. $1 is the reason. Sets
# canary_gave_up to 1 when it gave up, else 0.
canary_retry() {
    tries=$(($(number_in "$STATE/canary-tries") + 1))
    canary_gave_up=0
    if [ "$tries" -ge "$SIM_FLEET_CANARY_TRIES_MAX" ]; then
        log "canary $canary_runner: $1; gave up after $tries tries, the cycle moves on"
        canary_gave_up=1
        canary_done
    else
        echo "$tries" >"$STATE/canary-tries"
        log "canary $canary_runner: $1; it runs again next round (try $tries)"
    fi
}

# A canary the host kept from running $tries tries in a row is a blind spot the operator must
# see: one crash record under sim-canary (no seed in its text, so a lasting blind spot is one
# issue), which the tracker's day counts as a crash. The cycle has moved on, so the runner is
# tried again when its turn comes round; if GitHub refuses the record, the reporter leaves it in
# $STATE/last-failed-round-sim-canary.txt. $1 is the canary's worker.
canary_blind() {
    {
        printf 'seed %s: CRASHED: not run in %s tries\n' "$base" "$tries"
        printf '  step: canary\n'
        printf '  replay: zig-out/bin/%s --seeds %s..%s %s %s\n' "$canary_runner" "$base" \
            "$last" "$(kind_ops sim-canary)" "$(kind_flags sim-canary)"
        printf '%s: seeds %s..%s, %s: 1 of 1 failed\n' \
            "$(kind_prefix sim-canary)" "$base" "$base" "$(ops_phrase sim-canary)"
    } >"$round/blind-sim-canary"
    log "canary $canary_runner could not run in $tries tries: recording a blind spot"
    ingest sim-canary "$round/blind-sim-canary" "$base..$last" || true
}

# Collects canary worker $1 like any worker (a crash is replayed seed by seed and each crashed
# seed recorded); a run that timed out, was killed or refused its arguments is one crash record
# too, since a canary that cannot run proves nothing. Then `sim_fleet ingest --canary`. A run
# that was not caught keeps its output and stderr in $STATE/crashes.
canary_report() {
    code=$(cat "$round/code-$1")
    base=$(cat "$round/base-$1")
    last=$((base + canary_seeds - 1))
    case "$code" in
    0 | 1) collect "$1" sim-canary ;;
    124 | 137) canary_record "$1" "$code" ;;
    *)
        if [ "$code" -ge 128 ]; then
            collect "$1" sim-canary
        else
            canary_record "$1" "$code"
        fi
        ;;
    esac >"$round/all-sim-canary"
    ic=0
    ingest sim-canary "$round/all-sim-canary" "$base..$last" || ic=$?
    if [ "$ic" -ne 0 ]; then round_clean=""; fi
    # Exit 3: counted and judged, but GitHub kept part of it from being written (a hold, the
    # tracker, a locked issue); the cycle goes on as after 0, and the round is not clean.
    if [ "$ic" -eq 0 ] || [ "$ic" -eq 3 ]; then
        word=$(sed -n "s/^sim-fleet: canary $canary_runner: //p" "$round/ingest-sim-canary")
        if [ "$word" != caught ]; then keep_crash "$1" "canary-$canary_runner"; fi
        log "canary $canary_runner on seeds $base..$last: $word"
        if [ "$word" = "NOT RUN" ]; then
            canary_retry "no seed could run on this host"
            if [ "$canary_gave_up" -eq 1 ]; then canary_blind "$1"; fi
        else
            canary_done
        fi
    else
        keep_crash "$1" "canary-$canary_runner"
        if [ "$ic" -eq 2 ] || [ "$ic" -eq 124 ]; then
            # Exit 2 is any environment error of the reporter (GitHub asked to wait or stopped
            # the round, an unwritable or unreadable state file or token, no memory), 124 a
            # timeout: any of them may pass, and the cap bounds the ones that do not.
            canary_retry "was not filed (sim_fleet exited $ic)"
        else
            # The reporter refused the input (exit 1): another try gets the same answer.
            log "canary $canary_runner: sim_fleet exited $ic; the output is in $STATE/crashes" \
                "and the cycle moves on"
            canary_done
        fi
    fi
}

# The record of canary worker $1's whole run, which ended with exit code $2 and no output to
# read: one crash at its first seed, counted as that one seed (a kill for memory, 137, is the
# host's: step setup, counted and never filed).
canary_record() {
    case "$2" in
    124)
        # No seed or replay line in the message: it is part of the fingerprint, and one hang
        # under different profiles must stay one issue. The log has the seed.
        log "canary $canary_runner timed out on $(seed_in "$round/err-$1")" >&2
        verdict="CRASHED: timed out after $SIM_FLEET_BATCH_TIMEOUT s"
        where=canary
        ;;
    137)
        # The host's memory, not a bug of the canary: a record that is counted and not filed.
        log "canary $canary_runner was killed (out of memory?) on $(seed_in "$round/err-$1")" >&2
        verdict="FAILED: killed (out of memory?)"
        where=setup
        ;;
    *)
        verdict="CRASHED: exited $2: $(head -n1 "$round/err-$1")"
        where=canary
        ;;
    esac
    printf 'seed %s: %s\n' "$base" "$verdict"
    printf '  step: %s\n' "$where"
    printf '  replay: zig-out/bin/%s --seeds %s..%s %s %s\n' "$canary_runner" "$base" \
        "$last" "$(kind_ops sim-canary)" "$(kind_flags sim-canary)"
    printf '%s: seeds %s..%s, %s: 1 of 1 failed\n' "$(kind_prefix sim-canary)" \
        "$base" "$base" "$(ops_phrase sim-canary)"
}

start_worker() {
    base=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    if [ "$2" = sim-canary ] && [ -n "$canary_first" ]; then base=$canary_first; fi
    echo "$base" >"$round/base-$1"
    echo "$2" >"$round/kind-$1"
    exe=$(kind_exe "$2")
    flags=$(kind_flags "$2")
    ops=$(kind_ops "$2")
    # The cluster kinds write each seed's replay line to stderr as the seed starts, so a batch
    # that times out or is killed says which seed it was on (`sim_swarm` has no such flag).
    trace=$(kind_trace "$2")
    shrink=$(kind_shrink "$2")
    (
        code=0
        # shellcheck disable=SC2086 # $flags, $shrink and $trace are flags, or empty.
        timeout "$SIM_FLEET_BATCH_TIMEOUT" "$bin/$exe" \
            --seeds "$base..$((base + $(kind_batch "$2") - 1))" "$ops" $flags $shrink \
            $trace >"$round/out-$1" 2>"$round/err-$1" || code=$?
        echo "$code" >"$round/code-$1"
    ) &
}

# Prints worker $1's share of the round for the reporter: its output, or for a crash the replay
# of its range seed by seed. A timeout or a run killed for memory is the host's: logged, not
# counted. $2 is the kind.
collect() {
    base=$(cat "$round/base-$1")
    last=$((base + $(kind_batch "$2") - 1))
    code=$(cat "$round/code-$1")
    case "$code" in
    0 | 1) cat "$round/out-$1" ;;
    124)
        log "$2 timed out on seeds $base..$last at $built, on $(seed_in "$round/err-$1");" \
            "not counted" >&2
        ;;
    137)
        log "$2 was killed (out of memory?) on seeds $base..$last at $built," \
            "on $(seed_in "$round/err-$1"); not counted" >&2
        ;;
    *)
        if [ "$code" -lt 128 ]; then
            log "$2 exited $code on seeds $base..$last at $built; not counted" >&2
            return 0
        fi
        keep_crash "$1" "$2"
        log "$2 crashed (exit $code) on seeds $base..$last at $built;" \
            "replaying them one by one" >&2
        replay_range "$base" "$last" "$2"
        ;;
    esac
}

# The seed a run was on when it ended, from the last `replay:` line it traced to stderr file $1,
# and that line, so the log has the command that reproduces it.
seed_in() {
    line=$(sed -n 's/^ *replay: //p' "$1" | tail -n1)
    if [ -z "$line" ]; then echo "an unknown seed"; return 0; fi
    echo "seed $(echo "$line" | awk '{print $2}') ($line)"
}

# Keeps the crashed run's output and stderr (the last 20 crashes), named by kind (or for a
# canary that was not caught, `canary-<runner>`).
keep_crash() {
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$2-$1"
    cp "$round/out-$1" "$STATE/crashes/$stamp.out"
    cp "$round/err-$1" "$STATE/crashes/$stamp.err"
    # Newest first; past the 40 files of 20 crashes the rest go.
    ls -1t "$STATE/crashes" | tail -n +41 | while read -r old; do
        rm -f "$STATE/crashes/$old"
    done
}

# Runs seeds $1..$2 of kind $3 one at a time, printing each one's output, or for a seed that
# crashes a `seed N: CRASHED:` record with its panic message and the step it was in. The cluster
# kinds run with --trace-steps; `sim_swarm` has none.
replay_range() {
    seed=$1
    exe=$(kind_exe "$3")
    flags=$(kind_flags "$3")
    trace=$(kind_trace "$3")
    shrink=$(kind_shrink "$3")
    while [ "$seed" -le "$2" ]; do
        code=0
        # shellcheck disable=SC2086 # $flags and $trace are empty or one flag.
        timeout "$SIM_FLEET_BATCH_TIMEOUT" "$bin/$exe" --seeds "$seed..$seed" \
            "$(kind_ops "$3")" $flags $shrink $trace >"$round/one" 2>"$round/one.err" || code=$?
        case "$code" in
        0 | 1) cat "$round/one" ;;
        124 | 137)
            log "seed $seed timed out or was killed on replay ($(seed_in "$round/one.err"));" \
                "not counted" >&2
            ;;
        *) crash_record "$seed" "$code" "$3" ;;
        esac
        seed=$((seed + 1))
    done
}

# The record of seed $1 that crashed with exit code $2 in kind $3. The replay line is the one the
# run traced to stderr before it crashed (concrete: profile, ttl, replicas and heal point), else
# the command line the batch used.
crash_record() {
    message=$(sed -n 's/^.*panic: //p' "$round/one.err" | head -n1)
    if [ -z "$message" ]; then
        if [ "$2" -ge 128 ]; then
            message="killed by signal $(($2 - 128))"
        else
            message="exit $2"
        fi
    fi
    printf 'seed %s: CRASHED: %s\n' "$1" "$message"
    if [ "$(kind_sim "$3")" = sim-swarm ]; then
        printf '  step: run\n'
        printf '  replay: zig-out/bin/%s %s %s %s\n' "$(kind_exe "$3")" "$1" "$(kind_ops "$3")" \
            "$(kind_flags "$3")"
    else
        step=$(sed -n 's/^step: //p' "$round/one.err" | tail -n1)
        printf '  step: %s\n' "${step:-setup}"
        replay=$(sed -n 's/^ *replay: //p' "$round/one.err" | tail -n1)
        if [ -z "$replay" ]; then
            replay="zig-out/bin/$(kind_exe "$3") $1 $(kind_ops "$3") 0 $(kind_flags "$3")"
        fi
        printf '  replay: %s\n' "$replay"
    fi
    printf '%s: seeds %s..%s, %s: 1 of 1 failed\n' "$(kind_prefix "$3")" "$1" "$1" \
        "$(ops_phrase "$3")"
}

# Hands kind $1's file $2 to the reporter; for the canary, $3 is the seeds it ran. What the
# reporter prints is also kept in $round/ingest-$1. Returns its exit code: 3 is a round counted
# that GitHub kept part of from being written (not ingested again, so not kept as failed).
ingest() {
    kind=$1
    input=$2
    seeds=${3:-}
    set -- ingest --kind "$(kind_sim "$kind")" --commit "$built" --state "$STATE/state.txt" \
        --ref "${ref:--}" --round-started "${round_started:-$(date +%s)}"
    if [ "$kind" = sim-canary ]; then
        set -- "$@" --canary "$canary_runner" --canary-seeds "$seeds"
        if [ -n "$canary_symptom" ]; then set -- "$@" --expect-symptom "$canary_symptom"; fi
    fi
    if [ -n "$SIM_FLEET_DRY_RUN" ]; then
        set -- "$@" --dry-run
    else
        set -- "$@" --repo "$SIM_FLEET_GH_REPO" --token-file "$token_file"
    fi
    if [ -n "$SIM_FLEET_TRACKER" ]; then set -- "$@" --tracker "$SIM_FLEET_TRACKER"; fi
    code=0
    timeout "$SIM_FLEET_REPORT_TIMEOUT" "$reporter" "$@" <"$input" \
        >"$round/ingest-$kind" || code=$?
    cat "$round/ingest-$kind"
    if [ "$code" -eq 0 ]; then return 0; fi
    if [ "$code" -eq 3 ]; then
        log "sim_fleet ingest of $kind: counted, but GitHub kept part of it from being written" \
            "(see above); no heartbeat this round"
        return 3
    fi
    cp "$input" "$STATE/last-failed-round-$kind.txt"
    if [ "$code" -eq 124 ]; then
        log "sim_fleet ingest timed out; the round is in $STATE/last-failed-round-$kind.txt"
    else
        # sim_fleet said why on the line before; 2 with GitHub stopped is retried next round.
        log "sim_fleet ingest exited $code; the round is in $STATE/last-failed-round-$kind.txt"
    fi
    return "$code"
}

# Sourced by ops/sim-fleet/test-crash-record.sh and test-canary.sh for the functions only.
if [ -n "${SIM_FLEET_SOURCE_ONLY:-}" ]; then return 0 2>/dev/null || true; fi
main "$@"
exit $?
