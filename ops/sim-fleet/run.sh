#!/bin/sh
# The simulation fleet's loop (ops/sim-fleet/README.md): follow the tip of main, rebuild when it
# moves, run `sim_cluster` over fresh seeds in batches, and hand each batch to `sim_fleet ingest`.
# Settings come from the environment (the unit reads /etc/sim-fleet/fleet.env). The token is a
# file; this script never prints it.
set -eu

main() {
    : "${SIM_FLEET_REPO_DIR:=/var/lib/sim-fleet/zigcube}"
    : "${SIM_FLEET_STATE_DIR:=/var/lib/sim-fleet/state}"
    : "${SIM_FLEET_REMOTE:=https://github.com/Zigbox/zigcube}"
    : "${SIM_FLEET_GH_REPO:=Zigbox/zigcube}"
    : "${SIM_FLEET_BRANCH:=main}"
    : "${SIM_FLEET_OPS:=100}"
    : "${SIM_FLEET_BATCH:=100}"
    : "${SIM_FLEET_WORKERS:=3}"
    : "${SIM_FLEET_CACHE_MB:=8192}"
    : "${SIM_FLEET_TRACKER:=}"
    : "${SIM_FLEET_DRY_RUN:=}"
    token_file="${SIM_FLEET_TOKEN_FILE:-${CREDENTIALS_DIRECTORY:+$CREDENTIALS_DIRECTORY/token}}"
    mkdir -p "$SIM_FLEET_STATE_DIR"
    if [ ! -d "$SIM_FLEET_REPO_DIR/.git" ]; then
        git clone --quiet "$SIM_FLEET_REMOTE" "$SIM_FLEET_REPO_DIR"
    fi
    cd "$SIM_FLEET_REPO_DIR"
    built=""
    broken=""
    while true; do
        follow_main
        if [ -z "$built" ]; then
            log "nothing built yet; waiting"
            sleep 60
            continue
        fi
        run_batch
    done
}

log() {
    printf '%s sim-fleet: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# Fetches the branch; if its tip is a commit not built (and not already known to fail to build),
# builds it. A build that fails leaves the last good binaries in place and is logged once.
follow_main() {
    if ! git fetch --quiet origin "$SIM_FLEET_BRANCH"; then
        log "git fetch failed; keeping $built"
        return 0
    fi
    head=$(git rev-parse FETCH_HEAD)
    if [ "$head" = "$built" ] || [ "$head" = "$broken" ]; then
        return 0
    fi
    prune_cache
    git checkout --quiet --detach "$head"
    log "building $head"
    if zig build -Doptimize=ReleaseSafe sim-cluster-exe sim-fleet-exe >"$SIM_FLEET_STATE_DIR/build.log" 2>&1; then
        built="$head"
        log "built $head"
    else
        broken="$head"
        log "build of $head FAILED (see $SIM_FLEET_STATE_DIR/build.log); still testing ${built:-nothing}"
        if [ -n "$built" ]; then git checkout --quiet --detach "$built"; fi
    fi
}

# The build cache grows with every commit; past the limit it is emptied and the build starts cold.
prune_cache() {
    used=$(du -sm .zig-cache 2>/dev/null | cut -f1)
    if [ "${used:-0}" -gt "$SIM_FLEET_CACHE_MB" ]; then
        log ".zig-cache is ${used} MB (limit $SIM_FLEET_CACHE_MB); emptying it"
        rm -rf .zig-cache
    fi
}

# One round: SIM_FLEET_WORKERS parallel `sim_cluster` runs over fresh seed ranges (one core each;
# the default 3 leaves a core of a 4 vCPU host for the reporter, git and the build), then the
# reporter over each output in turn (the state file has one writer at a time). `sim_cluster`
# exits 1 when seeds failed (that is the point), so only a crash (2 or more) is an error.
run_batch() {
    w=0
    while [ "$w" -lt "$SIM_FLEET_WORKERS" ]; do
        base=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
        last=$((base + SIM_FLEET_BATCH - 1))
        echo "$base..$last" >"$SIM_FLEET_STATE_DIR/range-$w.txt"
        (
            code=0
            zig-out/bin/sim_cluster --seeds "$base..$last" "$SIM_FLEET_OPS" --shrink \
                >"$SIM_FLEET_STATE_DIR/batch-$w.txt" || code=$?
            echo "$code" >"$SIM_FLEET_STATE_DIR/code-$w.txt"
        ) &
        w=$((w + 1))
    done
    wait
    w=0
    while [ "$w" -lt "$SIM_FLEET_WORKERS" ]; do
        ingest_one "$w"
        w=$((w + 1))
    done
}

ingest_one() {
    out="$SIM_FLEET_STATE_DIR/batch-$1.txt"
    range=$(cat "$SIM_FLEET_STATE_DIR/range-$1.txt")
    code=$(cat "$SIM_FLEET_STATE_DIR/code-$1.txt")
    if [ "$code" -gt 1 ]; then
        log "sim_cluster crashed (exit $code) on seeds $range at $built; see $out"
        sleep 30
        return 0
    fi
    set -- ingest --commit "$built" --state "$SIM_FLEET_STATE_DIR/state.txt"
    if [ -n "$SIM_FLEET_DRY_RUN" ]; then
        set -- "$@" --dry-run
    else
        set -- "$@" --repo "$SIM_FLEET_GH_REPO" --token-file "$token_file"
    fi
    if [ -n "$SIM_FLEET_TRACKER" ]; then set -- "$@" --tracker "$SIM_FLEET_TRACKER"; fi
    if ! zig-out/bin/sim_fleet "$@" <"$out"; then
        log "sim_fleet ingest failed for seeds $range; see $out"
        sleep 60
    fi
}

main "$@"; exit $?
