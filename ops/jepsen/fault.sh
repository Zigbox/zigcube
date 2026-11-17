#!/usr/bin/env bash
# The faults of the Jepsen battery, on one host (docs/jepsen.md, "Faults", says what each does to
# Zigcube and what the checker must excuse). Run as root; idempotent and non-interactive.
#
#   fault.sh pause server|agent|postgres|PID     SIGSTOP (postgres: the postmaster and every
#                                                child, so the whole database stops)
#   fault.sh resume server|agent|postgres|PID    SIGCONT the same processes
#   fault.sh kill server|agent|PID               SIGKILL (the agent alone: its containers live
#                                                on; Postgres is `postgres.sh crash`)
#   fault.sh partition HOST...                   drop every packet to and from each HOST
#   fault.sh heal                                drop nothing (undo every partition)
#   fault.sh ntp-stop | ntp-start                stop or start time synchronisation
#   fault.sh clock-shift SECONDS                 stop NTP, move the clock by SECONDS (signed)
#   fault.sh clock-set EPOCH                     stop NTP, set the clock to EPOCH (seconds)
#
# server and agent are the units' main processes; postgres is the postmaster in ZCUBE_PG_DIR
# (default /var/lib/zcube-pg, as postgres.sh). ZCUBE_SYSTEMCTL replaces systemctl in tests.

set -euo pipefail

systemctl=${ZCUBE_SYSTEMCTL:-systemctl}
pg_dir=${ZCUBE_PG_DIR:-/var/lib/zcube-pg}
chain=ZCUBE_JEPSEN
ntp_units=(chrony chronyd ntp ntpsec systemd-timesyncd)

die() {
    echo "fault.sh: $*" >&2
    exit 1
}

main_pid() {
    local pid
    pid=$($systemctl show -p MainPID --value "zcube-$1")
    if [ -z "$pid" ] || [ "$pid" = 0 ]; then die "zcube-$1 is not running"; fi
    echo "$pid"
}

# The pid a target names (postgres: the postmaster).
pid_of() {
    case $1 in
        server | agent) main_pid "$1" ;;
        postgres)
            [ -f "$pg_dir/data/postmaster.pid" ] || die "no postmaster in $pg_dir/data"
            local postmaster
            postmaster=$(head -n 1 "$pg_dir/data/postmaster.pid")
            kill -0 "$postmaster" 2>/dev/null || die "the postmaster ($postmaster) is not running"
            echo "$postmaster"
            ;;
        *[!0-9]* | '') die "not server, agent, postgres or a pid: $1" ;;
        *) kill -0 "$1" 2>/dev/null || die "no process $1"; echo "$1" ;;
    esac
}

# Postgres is the postmaster and every child. Paused, the postmaster stops first, so it forks
# nothing more, and its children are listed and stopped until a listing finds none not yet
# stopped (one forked before the postmaster stopped may show up a moment late). Resumed, the
# children go on first and the postmaster last, so it never sees a stopped child.
signal_postgres() {
    local name=$1 postmaster children pid tries=0
    postmaster=$(pid_of postgres)
    if [ "$name" = STOP ]; then
        kill -STOP "$postmaster"
        local -A stopped=()
        while true; do
            local fresh=()
            for pid in $(pgrep -P "$postmaster" || true); do
                [ -n "${stopped[$pid]:-}" ] || fresh+=("$pid")
            done
            [ ${#fresh[@]} -gt 0 ] || break
            kill -STOP "${fresh[@]}" 2>/dev/null || true
            for pid in "${fresh[@]}"; do stopped[$pid]=1; done
            tries=$((tries + 1))
            [ $tries -le 100 ] || die "the postmaster's children kept changing"
        done
    else
        children=$(pgrep -P "$postmaster" || true)
        # shellcheck disable=SC2086 # One pid per word.
        if [ -n "$children" ]; then kill -"$name" $children 2>/dev/null || true; fi
        kill -"$name" "$postmaster"
    fi
}

signal() {
    local name=$1 target=$2
    if [ "$target" = postgres ] && [ "$name" != KILL ]; then
        signal_postgres "$name"
        return
    fi
    kill -"$name" "$(pid_of "$target")"
}

chain_up() {
    iptables -N "$chain" 2>/dev/null || true
    local hook
    for hook in INPUT OUTPUT; do
        iptables -C "$hook" -j "$chain" 2>/dev/null || iptables -I "$hook" 1 -j "$chain"
    done
}

cmd_partition() {
    [ $# -ge 1 ] || die "partition needs at least one HOST"
    chain_up
    local host side
    for host in "$@"; do
        for side in -s -d; do
            iptables -C "$chain" "$side" "$host" -j DROP 2>/dev/null ||
                iptables -A "$chain" "$side" "$host" -j DROP
        done
    done
}

cmd_heal() {
    if iptables -L "$chain" -n >/dev/null 2>&1; then iptables -F "$chain"; fi
}

cmd_ntp() {
    local verb=$1 unit
    if command -v timedatectl >/dev/null; then
        if [ "$verb" = stop ]; then timedatectl set-ntp false; else timedatectl set-ntp true; fi
    fi
    for unit in "${ntp_units[@]}"; do
        if $systemctl cat "$unit.service" >/dev/null 2>&1; then $systemctl "$verb" "$unit"; fi
    done
}

cmd_clock_shift() {
    [ $# -eq 1 ] || die "clock-shift needs SECONDS"
    # The whole value, before anything changes: it goes into shell arithmetic.
    [[ $1 =~ ^[+-]?[0-9]+$ ]] || die "not a whole number of seconds: $1"
    cmd_ntp stop
    date -s "@$(( $(date +%s) + 10#${1#[+-]} * ${1%%[0-9]*}1 ))" >/dev/null
}

cmd_clock_set() {
    [ $# -eq 1 ] || die "clock-set needs EPOCH"
    case $1 in '' | *[!0-9]*) die "not a time in seconds since 1970: $1" ;; esac
    cmd_ntp stop
    date -s "@$1" >/dev/null
}

[ "$(id -u)" = 0 ] || die "run as root"
[ $# -ge 1 ] || die "usage: fault.sh pause|resume|kill|partition|heal|ntp-stop|ntp-start|" \
    "clock-shift|clock-set ..."
command=$1
shift
case $command in
    pause) [ $# -eq 1 ] || die "pause needs a target"; signal STOP "$1" ;;
    resume) [ $# -eq 1 ] || die "resume needs a target"; signal CONT "$1" ;;
    kill)
        [ $# -eq 1 ] || die "kill needs a target"
        [ "$1" != postgres ] || die "Postgres is killed with postgres.sh crash"
        signal KILL "$1"
        ;;
    partition) cmd_partition "$@" ;;
    heal) cmd_heal ;;
    ntp-stop) cmd_ntp stop ;;
    ntp-start) cmd_ntp start ;;
    clock-shift) cmd_clock_shift "$@" ;;
    clock-set) cmd_clock_set "$@" ;;
    *) die "unknown command: $command" ;;
esac
