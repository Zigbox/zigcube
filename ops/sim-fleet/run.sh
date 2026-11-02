#!/bin/sh
# The simulation fleet's loop (ops/sim-fleet/README.md): follow the tip of main, rebuild when it
# moves, run `sim_cluster` over fresh seeds in parallel batches, and hand each round (every
# batch, plus a record of each crashed seed) to `sim_fleet ingest` once. Settings come from the
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
    : "${SIM_FLEET_OPS:=100}"
    : "${SIM_FLEET_BATCH:=100}"
    : "${SIM_FLEET_WORKERS:=3}"
    : "${SIM_FLEET_CACHE_MB:=8192}"
    : "${SIM_FLEET_TRACKER:=}"
    # Deadlines, in seconds: nothing the loop waits on may hang it.
    : "${SIM_FLEET_GIT_TIMEOUT:=300}"
    : "${SIM_FLEET_BUILD_TIMEOUT:=3600}"
    : "${SIM_FLEET_BATCH_TIMEOUT:=3600}"
    : "${SIM_FLEET_REPORT_TIMEOUT:=600}"
    # 0: run forever (the service). N: stop after N rounds (a dry run, a test).
    : "${SIM_FLEET_ROUNDS:=0}"
    : "${SIM_FLEET_IDLE_SECONDS:=60}"
    token_file="${SIM_FLEET_TOKEN_FILE:-${CREDENTIALS_DIRECTORY:+$CREDENTIALS_DIRECTORY/token}}"
    if [ -z "$SIM_FLEET_DRY_RUN" ] && [ -z "$token_file" ]; then
        log "no token: set SIM_FLEET_TOKEN_FILE, run under the unit, or set SIM_FLEET_DRY_RUN=1"
        exit 2
    fi
    STATE=$SIM_FLEET_STATE_DIR
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
    if [ -n "$built" ] && [ ! -x "$STATE/bin/$built/bin/sim_cluster" ]; then built=""; fi
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
        --prefix "$STATE/bin/$head" sim-cluster-exe sim-fleet-exe >"$STATE/build.log" 2>&1; then
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

# One round: SIM_FLEET_WORKERS parallel `sim_cluster` runs over fresh seed ranges (one core each;
# the default 3 leaves a core of a 4 vCPU host for the reporter, git and the build), then one
# `sim_fleet ingest` of everything the round found. `sim_cluster` exits 1 when seeds failed (that
# is the point); a run killed by a signal crashed, and its range is replayed seed by seed.
run_round() {
    bin="$STATE/bin/$built/bin"
    round="$STATE/round"
    rm -rf "$round"
    mkdir -p "$round"
    w=0
    while [ "$w" -lt "$SIM_FLEET_WORKERS" ]; do
        base=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
        echo "$base" >"$round/base-$w"
        (
            code=0
            timeout "$SIM_FLEET_BATCH_TIMEOUT" "$bin/sim_cluster" \
                --seeds "$base..$((base + SIM_FLEET_BATCH - 1))" "$SIM_FLEET_OPS" --shrink \
                >"$round/out-$w" 2>"$round/err-$w" || code=$?
            echo "$code" >"$round/code-$w"
        ) &
        w=$((w + 1))
    done
    wait
    : >"$round/all"
    w=0
    while [ "$w" -lt "$SIM_FLEET_WORKERS" ]; do
        collect "$w" >>"$round/all"
        w=$((w + 1))
    done
    if [ -s "$round/all" ]; then ingest "$round/all"; fi
}

# Prints worker $1's share of the round for the reporter: its output, or for a crash the replay
# of its range seed by seed. A timeout or a run killed for memory is the host's: logged, not
# counted.
collect() {
    base=$(cat "$round/base-$1")
    last=$((base + SIM_FLEET_BATCH - 1))
    code=$(cat "$round/code-$1")
    case "$code" in
    0 | 1) cat "$round/out-$1" ;;
    124) log "sim_cluster timed out on seeds $base..$last at $built; not counted" >&2 ;;
    137)
        log "sim_cluster was killed (out of memory?) on seeds $base..$last at $built;" \
            "not counted" >&2
        ;;
    *)
        if [ "$code" -lt 128 ]; then
            log "sim_cluster exited $code on seeds $base..$last at $built; not counted" >&2
            return 0
        fi
        keep_crash "$1"
        log "sim_cluster crashed (exit $code) on seeds $base..$last at $built;" \
            "replaying them one by one" >&2
        replay_range "$base" "$last"
        ;;
    esac
}

# Keeps the crashed run's output and stderr (the last 20 crashes).
keep_crash() {
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$1"
    cp "$round/out-$1" "$STATE/crashes/$stamp.out"
    cp "$round/err-$1" "$STATE/crashes/$stamp.err"
    # Newest first; past the 40 files of 20 crashes the rest go.
    ls -1t "$STATE/crashes" | tail -n +41 | while read -r old; do
        rm -f "$STATE/crashes/$old"
    done
}

# Runs seeds $1..$2 one at a time with --trace-steps, printing each one's output, or for a seed
# that crashes a `seed N: CRASHED:` record with its panic message and the step it was in.
replay_range() {
    seed=$1
    while [ "$seed" -le "$2" ]; do
        code=0
        timeout "$SIM_FLEET_BATCH_TIMEOUT" "$bin/sim_cluster" --seeds "$seed..$seed" \
            "$SIM_FLEET_OPS" --shrink --trace-steps >"$round/one" 2>"$round/one.err" || code=$?
        case "$code" in
        0 | 1) cat "$round/one" ;;
        124 | 137) log "seed $seed timed out or was killed on replay; not counted" >&2 ;;
        *) crash_record "$seed" "$code" ;;
        esac
        seed=$((seed + 1))
    done
}

crash_record() {
    message=$(sed -n 's/^.*panic: //p' "$round/one.err" | head -n1)
    if [ -z "$message" ]; then
        if [ "$2" -ge 128 ]; then
            message="killed by signal $(($2 - 128))"
        else
            message="exit $2"
        fi
    fi
    step=$(sed -n 's/^step: //p' "$round/one.err" | tail -n1)
    printf 'seed %s: CRASHED: %s\n' "$1" "$message"
    printf '  step: %s\n' "${step:-setup}"
    printf '  replay: zig-out/bin/sim_cluster %s %s 0\n' "$1" "$SIM_FLEET_OPS"
    printf 'sim-cluster: seeds %s..%s, %s operations: 1 of 1 failed\n' "$1" "$1" "$SIM_FLEET_OPS"
}

ingest() {
    set -- ingest --commit "$built" --state "$STATE/state.txt"
    if [ -n "$SIM_FLEET_DRY_RUN" ]; then
        set -- "$@" --dry-run
    else
        set -- "$@" --repo "$SIM_FLEET_GH_REPO" --token-file "$token_file"
    fi
    if [ -n "$SIM_FLEET_TRACKER" ]; then set -- "$@" --tracker "$SIM_FLEET_TRACKER"; fi
    code=0
    timeout "$SIM_FLEET_REPORT_TIMEOUT" "$bin/sim_fleet" "$@" <"$round/all" || code=$?
    if [ "$code" -eq 0 ]; then return 0; fi
    cp "$round/all" "$STATE/last-failed-round.txt"
    if [ "$code" -eq 124 ]; then
        log "sim_fleet ingest timed out; the round is in $STATE/last-failed-round.txt"
    else
        # sim_fleet said why on the line before; 2 with GitHub stopped is retried next round.
        log "sim_fleet ingest exited $code; the round is in $STATE/last-failed-round.txt"
    fi
}

main "$@"
exit $?
