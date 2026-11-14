#!/bin/sh
# The long soak (ops/sim-fleet/README.md, item 7; docs/briefs/c3.md, item 6): one seed of
# `sim_cluster` for hours, judged at every epoch (src/sim_soak.zig) for leaks, counters near
# their range and a world that stopped moving, then handed to `sim_fleet ingest --kind sim-soak`.
# It runs beside run.sh, not inside it: it takes the binaries run.sh last built
# ($SIM_FLEET_STATE_DIR/built), copies them so run.sh may prune them meanwhile, and keeps a
# state file of its own. One soak per round; SIM_SOAK_ROUNDS=0 (the default) loops for ever.
# The token is a file; this script never prints it.
set -eu

main() {
    : "${SIM_FLEET_HOME:=/var/lib/sim-fleet}"
    : "${SIM_FLEET_DRY_RUN:=}"
    if [ -n "$SIM_FLEET_DRY_RUN" ]; then
        : "${SIM_FLEET_STATE_DIR:=$SIM_FLEET_HOME/dry/state}"
    else
        : "${SIM_FLEET_STATE_DIR:=$SIM_FLEET_HOME/state}"
    fi
    : "${SIM_FLEET_GH_REPO:=Zigbox/zigcube}"
    : "${SIM_FLEET_REPORT_TIMEOUT:=600}"
    # How long one seed runs, in minutes, and the operations between two judgements.
    : "${SIM_SOAK_MINUTES:=360}"
    : "${SIM_SOAK_EPOCH:=500}"
    # A fixed seed (a number) soaks that seed every round; empty draws a fresh one each round.
    : "${SIM_SOAK_SEED:=}"
    : "${SIM_SOAK_ROUNDS:=0}"
    # Seconds to wait when run.sh has built nothing yet.
    : "${SIM_SOAK_IDLE_SECONDS:=300}"
    for setting in SIM_SOAK_MINUTES SIM_SOAK_EPOCH SIM_SOAK_ROUNDS SIM_SOAK_IDLE_SECONDS; do
        eval "value=\$$setting"
        case $value in
        '' | *[!0-9]*)
            log "$setting is '$value': it must be a number"
            exit 2
            ;;
        esac
    done
    if [ "$SIM_SOAK_MINUTES" -eq 0 ] || [ "$SIM_SOAK_EPOCH" -eq 0 ]; then
        log "SIM_SOAK_MINUTES and SIM_SOAK_EPOCH must be 1 or more"
        exit 2
    fi
    case $SIM_SOAK_SEED in *[!0-9]*)
        log "SIM_SOAK_SEED is '$SIM_SOAK_SEED': it must be a number or empty"
        exit 2
        ;;
    esac
    token_file="${SIM_FLEET_TOKEN_FILE:-${CREDENTIALS_DIRECTORY:+$CREDENTIALS_DIRECTORY/token}}"
    if [ -z "$SIM_FLEET_DRY_RUN" ] && [ -z "$token_file" ]; then
        log "no token: set SIM_FLEET_TOKEN_FILE, run under the unit, or set SIM_FLEET_DRY_RUN=1"
        exit 2
    fi
    FLEET=$SIM_FLEET_STATE_DIR
    SOAK=$FLEET/soak
    mkdir -p "$SOAK"
    exec 8>"$SOAK/lock"
    if ! flock -n 8; then
        log "another soak.sh holds $SOAK/lock; exiting"
        exit 2
    fi
    rounds=0
    while [ "$SIM_SOAK_ROUNDS" -eq 0 ] || [ "$rounds" -lt "$SIM_SOAK_ROUNDS" ]; do
        if ! take_binaries; then
            log "run.sh has built nothing yet; waiting"
            sleep "$SIM_SOAK_IDLE_SECONDS"
            continue
        fi
        rounds=$((rounds + 1))
        soak_round
    done
}

log() {
    printf '%s sim-soak: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# Copies the binaries of the commit run.sh last built into $SOAK/bin and sets $built; fails when
# there are none.
take_binaries() {
    built=$(cat "$FLEET/built" 2>/dev/null || true)
    if [ -z "$built" ]; then return 1; fi
    from=$FLEET/bin/$built/bin
    if [ ! -x "$from/sim_cluster" ] || [ ! -x "$from/sim_fleet" ]; then return 1; fi
    rm -rf "$SOAK/bin.new"
    mkdir -p "$SOAK/bin.new"
    cp "$from/sim_cluster" "$from/sim_fleet" "$SOAK/bin.new/" || return 1
    rm -rf "$SOAK/bin"
    mv "$SOAK/bin.new" "$SOAK/bin"
}

# One seed: soaks it, keeps its output in $SOAK/last.log (the round before in last-1.log), and
# hands the verdict to the reporter. A run that died is recorded as `CRASHED` with a replay of
# the operations its last epoch line reached plus one epoch.
soak_round() {
    seed=${SIM_SOAK_SEED:-$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')}
    if [ -f "$SOAK/last.log" ]; then mv "$SOAK/last.log" "$SOAK/last-1.log"; fi
    log "soaking seed $seed for $SIM_SOAK_MINUTES minutes at $built"
    code=0
    "$SOAK/bin/sim_cluster" "$seed" soak --soak-minutes="$SIM_SOAK_MINUTES" \
        --soak-epoch="$SIM_SOAK_EPOCH" >"$SOAK/last.log" 2>"$SOAK/last.err" || code=$?
    case $code in
    0 | 1) cp "$SOAK/last.log" "$SOAK/verdict" ;;
    *)
        log "sim_cluster exited $code on seed $seed; recording a crash"
        crash_record "$seed" "$code" >"$SOAK/verdict"
        ;;
    esac
    tail -n 1 "$SOAK/verdict" | sed 's/^/  /'
    ingest || true
}

# The verdict of a soak of seed $1 that exited $2: the panic or the signal, the operations its
# last epoch reached, and the summary line the reporter counts the seed by.
crash_record() {
    message=$(sed -n 's/^.*panic: //p' "$SOAK/last.err" | head -n1)
    if [ -z "$message" ]; then
        if [ "$2" -ge 128 ]; then
            message="killed by signal $(($2 - 128))"
        else
            message="exit $2"
        fi
    fi
    reached=$(sed -n 's/^soak: epoch [0-9]* operations=\([0-9]*\) .*/\1/p' "$SOAK/last.log" |
        tail -n1)
    operations=$((${reached:-0} + SIM_SOAK_EPOCH))
    printf 'seed %s: CRASHED: %s\n  step: soak\n' "$1" "$message"
    printf '  replay: zig-out/bin/sim_cluster %s soak --soak-operations=%s --soak-epoch=%s\n' \
        "$1" "$operations" "$SIM_SOAK_EPOCH"
    printf 'sim-cluster --soak: seeds %s..%s, %s operations: 1 of 1 failed\n' \
        "$1" "$1" "$operations"
}

# Hands $SOAK/verdict to `sim_fleet ingest --kind sim-soak`. Its state file is the soak's own:
# run.sh holds the fleet's, and the daily tracker post stays run.sh's. A verdict the reporter
# did not take is kept in $SOAK/last-failed-verdict.txt.
ingest() {
    set -- ingest --kind sim-soak --commit "$built" --state "$SOAK/state.txt"
    if [ -n "$SIM_FLEET_DRY_RUN" ]; then
        set -- "$@" --dry-run
    else
        set -- "$@" --repo "$SIM_FLEET_GH_REPO" --token-file "$token_file"
    fi
    code=0
    timeout "$SIM_FLEET_REPORT_TIMEOUT" "$SOAK/bin/sim_fleet" "$@" <"$SOAK/verdict" \
        >"$SOAK/ingest.out" || code=$?
    cat "$SOAK/ingest.out"
    if [ "$code" -eq 0 ]; then return 0; fi
    cp "$SOAK/verdict" "$SOAK/last-failed-verdict.txt"
    log "sim_fleet ingest exited $code; the verdict is in $SOAK/last-failed-verdict.txt"
    return "$code"
}

# Sourced by ops/sim-fleet/test-soak.sh for the functions only.
if [ -n "${SIM_FLEET_SOURCE_ONLY:-}" ]; then return 0 2>/dev/null || true; fi
main "$@"
exit $?
