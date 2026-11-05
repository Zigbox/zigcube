#!/bin/sh
# The simulation fleet's loop (ops/sim-fleet/README.md): follow the tip of main, rebuild when it
# moves, run three producers over fresh seeds in parallel batches (`sim_cluster`, `sim_cluster
# --c1` and `sim_swarm`; the kinds `sim-cluster`, `sim-c1`, `sim-swarm`), and hand each round
# (every batch, plus a record of each crashed seed) to `sim_fleet ingest`, once per kind. Settings come from the
# environment (the unit reads /etc/sim-fleet/fleet.env). The token is a file; this script never
# prints it.
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
    # 100 (setup.sh never overwrites it) and the swarm worker would idle. A swarm seed takes ~1.5 ms to a cluster seed's ~1.1 s (measured 2026-11-04, ReleaseSafe, 100
    # operations), so 50000 keep its core about as busy as 100 cluster seeds keep theirs.
    : "${SIM_FLEET_BATCH_CLUSTER:=$SIM_FLEET_BATCH}"
    : "${SIM_FLEET_BATCH_C1:=$SIM_FLEET_BATCH}"
    : "${SIM_FLEET_BATCH_SWARM:=50000}"
    # Parallel workers per kind (one core each): 1 + 1 + 1 leaves a core of a 4 vCPU host for the
    # reporter, git and builds. A kind set to 0 is not run.
    : "${SIM_FLEET_WORKERS_CLUSTER:=1}"
    : "${SIM_FLEET_WORKERS_C1:=1}"
    : "${SIM_FLEET_WORKERS_SWARM:=1}"
    : "${SIM_FLEET_CACHE_MB:=8192}"
    # The teeth canary: about 1 round in this many also runs one fault-on runner that must fail
    # (canary_round); 0 never does, 1 every round. A miss is filed as an issue.
    : "${SIM_FLEET_CANARY_ONE_IN:=50}"
    : "${SIM_FLEET_CANARY_TIMEOUT:=600}"
    : "${SIM_FLEET_TRACKER:=}"
    # Deadlines, in seconds: nothing the loop waits on may hang it.
    : "${SIM_FLEET_GIT_TIMEOUT:=300}"
    : "${SIM_FLEET_BUILD_TIMEOUT:=3600}"
    : "${SIM_FLEET_BATCH_TIMEOUT:=3600}"
    : "${SIM_FLEET_REPORT_TIMEOUT:=600}"
    # 0: run forever (the service). N: stop after N rounds (a dry run, a test).
    : "${SIM_FLEET_ROUNDS:=0}"
    : "${SIM_FLEET_IDLE_SECONDS:=60}"
    if [ -n "${SIM_FLEET_WORKERS:-}" ]; then
        log "SIM_FLEET_WORKERS is ignored: set SIM_FLEET_WORKERS_CLUSTER, _C1 and _SWARM"
    fi
    token_file="${SIM_FLEET_TOKEN_FILE:-${CREDENTIALS_DIRECTORY:+$CREDENTIALS_DIRECTORY/token}}"
    if [ -z "$SIM_FLEET_DRY_RUN" ] && [ -z "$token_file" ]; then
        log "no token: set SIM_FLEET_TOKEN_FILE, run under the unit, or set SIM_FLEET_DRY_RUN=1"
        exit 2
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
    # Remembered across restarts: a restart neither rebuilds a good commit nor retries a bad one.
    built=$(cat "$STATE/built" 2>/dev/null || true)
    broken=$(cat "$STATE/broken" 2>/dev/null || true)
    if [ -n "$built" ] && [ ! -x "$STATE/bin/$built/bin/sim_swarm" ]; then built=""; fi
    rounds=0
    while [ "$SIM_FLEET_ROUNDS" -eq 0 ] || [ "$rounds" -lt "$SIM_FLEET_ROUNDS" ]; do
        rounds=$((rounds + 1))
        follow_main
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

# Fetches the branch; if its tip is a commit not built (and not already known to fail to build),
# builds it into a directory of its own and switches to it only once the build succeeded. A
# build that fails leaves the last good binaries in use and is logged once.
follow_main() {
    if ! timeout "$SIM_FLEET_GIT_TIMEOUT" git fetch --quiet origin "$SIM_FLEET_BRANCH"; then
        log "git fetch failed or timed out; keeping ${built:-nothing}"
        return 0
    fi
    head=$(git rev-parse FETCH_HEAD)
    if [ "$head" = "$built" ] || [ "$head" = "$broken" ]; then
        return 0
    fi
    prune_cache
    git checkout --quiet --detach "$head"
    log "building $head"
    rm -rf "$STATE/bin/$head"
    if timeout "$SIM_FLEET_BUILD_TIMEOUT" zig build -Doptimize=ReleaseSafe \
        --prefix "$STATE/bin/$head" sim-cluster-exe sim-swarm-exe sim-fleet-exe \
        sim-canary-exe >"$STATE/build.log" 2>&1; then
        echo "$head" >"$STATE/built.new"
        mv "$STATE/built.new" "$STATE/built"
        built="$head"
        log "built $head"
        prune_bin
    else
        rm -rf "$STATE/bin/$head"
        echo "$head" >"$STATE/broken.new"
        mv "$STATE/broken.new" "$STATE/broken"
        broken="$head"
        log "build of $head FAILED or timed out (see $STATE/build.log);" \
            "still testing ${built:-nothing}"
    fi
}

# The binaries of every commit but the one in use.
prune_bin() {
    for dir in "$STATE"/bin/*; do
        [ -d "$dir" ] || continue
        if [ "$(basename "$dir")" != "$built" ]; then rm -rf "$dir"; fi
    done
}

# The build caches grow with every commit; past the limit they are emptied and the next build
# starts cold (and fetches its packages again).
prune_cache() {
    used=$(du -smc .zig-cache zig-pkg "$HOME/.cache/zig" 2>/dev/null | tail -n1 | cut -f1)
    if [ "${used:-0}" -gt "$SIM_FLEET_CACHE_MB" ]; then
        log "build caches are ${used} MB (limit $SIM_FLEET_CACHE_MB); emptying them"
        rm -rf .zig-cache zig-pkg "$HOME/.cache/zig"
    fi
}

# The executable that produces kind $1, and the flags that make it that kind.
kind_exe() {
    case "$1" in
    sim-swarm) echo sim_swarm ;;
    *) echo sim_cluster ;;
    esac
}

kind_flags() {
    case "$1" in
    sim-c1) echo "--c1 --profile=$SIM_FLEET_PROFILE" ;;
    *) echo "--profile=$SIM_FLEET_PROFILE" ;;
    esac
}

# The summary line's operations, as the producers print it: `N operations`, or for a drawn size
# `drawn operations` (src/sim_fleet_issue.zig reads both).
ops_phrase() {
    if [ "$SIM_FLEET_OPS" = auto ]; then echo "drawn operations"; else echo "$SIM_FLEET_OPS operations"; fi
}

# The summary line's prefix and the step of a crash that left none: `sim_swarm` has no
# --trace-steps, so a swarm crash is in the step "run".
kind_prefix() {
    case "$1" in
    sim-swarm) echo sim-swarm ;;
    sim-c1) echo "sim-cluster --c1" ;;
    *) echo sim-cluster ;;
    esac
}

# Seeds per batch of kind $1 (defaults above).
kind_batch() {
    case "$1" in
    sim-cluster) echo "$SIM_FLEET_BATCH_CLUSTER" ;;
    sim-c1) echo "$SIM_FLEET_BATCH_C1" ;;
    *) echo "$SIM_FLEET_BATCH_SWARM" ;;
    esac
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
# replayed seed by seed. Workers are numbered across kinds; `$round/kind-W` names worker W's.
run_round() {
    bin="$STATE/bin/$built/bin"
    round="$STATE/round"
    rm -rf "$round"
    mkdir -p "$round"
    workers=0
    for kind in $KINDS; do
        n=$(kind_workers "$kind")
        i=0
        while [ "$i" -lt "$n" ]; do
            start_worker "$workers" "$kind"
            workers=$((workers + 1))
            i=$((i + 1))
        done
    done
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
        if [ -s "$round/all-$kind" ]; then ingest "$kind" "$round/all-$kind"; fi
    done
    canary_round
}

# The teeth canary (docs/briefs/c3-sim-fleet.md, item 3): the fleet's own proof that it still
# detects. These are the runners `zig build sim-canary-exe` installs, each built with one
# test-only fault on and each of which must fail within seeds 1..10 (`--expect-fail` exits 0
# when one does, 1 when none does). The faults and symptoms are build.zig's `c1_teeth_roots`,
# `sim-teeth` and `sim-swarm-teeth`; keep this list the same.
CANARIES="sim_teeth sim_swarm_teeth sim_c1_teeth_allocation sim_c1_teeth_readiness \
    sim_c1_teeth_stale sim_c1_teeth_skew sim_c1_teeth_wedge sim_c1_teeth_locality"

canary_symptom() {
    case "$1" in
    sim_c1_teeth_allocation) echo I6 ;;
    sim_c1_teeth_readiness) echo I7 ;;
    sim_c1_teeth_stale) echo I3 ;;
    sim_c1_teeth_skew) echo I1b ;;
    sim_c1_teeth_wedge) echo "I1b: a replaced replica kept executing longer" ;;
    sim_c1_teeth_locality) echo L1 ;;
    esac
}

# A random number from the kernel.
draw() {
    od -An -N4 -tu4 /dev/urandom | tr -d ' '
}

# About 1 round in SIM_FLEET_CANARY_ONE_IN: runs one canary, picked at random, and hands the
# reporter kind `sim-canary`: a run that failed as it must is one seed counted, a run whose
# fault went undetected is a failure at the step `canary` (an issue, "the fleet has stopped
# detecting"). A crash, a timeout or a missing runner is the host's: logged, not counted.
canary_round() {
    one_in=$SIM_FLEET_CANARY_ONE_IN
    if [ "$one_in" -le 0 ] || [ $(($(draw) % one_in)) -ne 0 ]; then return 0; fi
    set -- $CANARIES
    pick=$(($(draw) % $#))
    shift "$pick"
    name=$1
    if [ ! -x "$bin/$name" ]; then
        log "canary $name is not built at $built; skipped"
        return 0
    fi
    set -- --seeds 1..10 100
    case "$name" in sim_c1_*) set -- "$@" --c1 ;; esac
    replay_args="$*"
    symptom=$(canary_symptom "$name")
    set -- "$@" --expect-fail
    if [ -n "$symptom" ]; then set -- "$@" "--expect-symptom=$symptom"; fi
    code=0
    timeout "$SIM_FLEET_CANARY_TIMEOUT" "$bin/$name" "$@" >"$round/canary.out" \
        2>"$round/canary.err" || code=$?
    case "$code" in
    0) failed=0 ;;
    1) failed=1 ;;
    *)
        log "canary $name exited $code at $built; not counted"
        return 0
        ;;
    esac
    {
        if [ "$failed" -eq 1 ]; then
            printf 'seed 1: FAILED: the fleet has stopped detecting: %s ran seeds 1..10 and none failed\n' "$name"
            printf '  step: canary\n  replay: zig-out/bin/%s %s\n' "$name" "$replay_args"
        fi
        printf 'sim-canary: seeds 1..1, 100 operations: %s of 1 failed\n' "$failed"
    } >"$round/all-sim-canary"
    log "canary $name: $(if [ "$failed" -eq 1 ]; then echo MISSED; else echo caught; fi)"
    ingest sim-canary "$round/all-sim-canary"
}

start_worker() {
    base=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    echo "$base" >"$round/base-$1"
    echo "$2" >"$round/kind-$1"
    exe=$(kind_exe "$2")
    flags=$(kind_flags "$2")
    trace=""
    # The cluster kinds write each seed's replay line to stderr as the seed starts, so a batch
    # that times out or is killed says which seed it was on (`sim_swarm` has no such flag).
    if [ "$exe" = sim_cluster ]; then trace=--trace-steps; fi
    (
        code=0
        # shellcheck disable=SC2086 # $flags and $trace are flags, never empty words.
        timeout "$SIM_FLEET_BATCH_TIMEOUT" "$bin/$exe" \
            --seeds "$base..$((base + $(kind_batch "$2") - 1))" "$SIM_FLEET_OPS" $flags --shrink \
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

# Keeps the crashed run's output and stderr (the last 20 crashes), named by kind.
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
    trace=""
    if [ "$exe" = sim_cluster ]; then trace=--trace-steps; fi
    while [ "$seed" -le "$2" ]; do
        code=0
        # shellcheck disable=SC2086 # $flags and $trace are empty or one flag.
        timeout "$SIM_FLEET_BATCH_TIMEOUT" "$bin/$exe" --seeds "$seed..$seed" \
            "$SIM_FLEET_OPS" $flags --shrink $trace >"$round/one" 2>"$round/one.err" || code=$?
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
    if [ "$(kind_exe "$3")" = sim_swarm ]; then
        printf '  step: run\n'
        printf '  replay: zig-out/bin/sim_swarm %s %s %s\n' "$1" "$SIM_FLEET_OPS" "$(kind_flags "$3")"
    else
        step=$(sed -n 's/^step: //p' "$round/one.err" | tail -n1)
        printf '  step: %s\n' "${step:-setup}"
        replay=$(sed -n 's/^ *replay: //p' "$round/one.err" | tail -n1)
        if [ -z "$replay" ]; then
            replay="zig-out/bin/sim_cluster $1 $SIM_FLEET_OPS 0 $(kind_flags "$3")"
        fi
        printf '  replay: %s\n' "$replay"
    fi
    printf '%s: seeds %s..%s, %s: 1 of 1 failed\n' "$(kind_prefix "$3")" "$1" "$1" "$(ops_phrase)"
}

# Hands kind $1's file $2 to the reporter.
ingest() {
    kind=$1
    input=$2
    set -- ingest --kind "$kind" --commit "$built" --state "$STATE/state.txt"
    if [ -n "$SIM_FLEET_DRY_RUN" ]; then
        set -- "$@" --dry-run
    else
        set -- "$@" --repo "$SIM_FLEET_GH_REPO" --token-file "$token_file"
    fi
    if [ -n "$SIM_FLEET_TRACKER" ]; then set -- "$@" --tracker "$SIM_FLEET_TRACKER"; fi
    code=0
    timeout "$SIM_FLEET_REPORT_TIMEOUT" "$bin/sim_fleet" "$@" <"$input" || code=$?
    if [ "$code" -eq 0 ]; then return 0; fi
    cp "$input" "$STATE/last-failed-round-$kind.txt"
    if [ "$code" -eq 124 ]; then
        log "sim_fleet ingest timed out; the round is in $STATE/last-failed-round-$kind.txt"
    else
        # sim_fleet said why on the line before; 2 with GitHub stopped is retried next round.
        log "sim_fleet ingest exited $code; the round is in $STATE/last-failed-round-$kind.txt"
    fi
}

# Sourced by ops/sim-fleet/test-crash-record.sh for the functions only.
if [ -n "${SIM_FLEET_SOURCE_ONLY:-}" ]; then return 0 2>/dev/null || true; fi
main "$@"
exit $?
