#!/bin/sh
# The guest half of `zig build demo-c3` (src/demo_c3.zig, docs/demos/c3.md). The host half boots
# three guests (the rig of src/demo_c2_vms.zig), copies the binaries and this script in, and calls
# it as root with one command at a time. The server runs on the host; this guest runs one
# `zcube-agent --runtime zigbox` as root (as demo-c2's, ops/demo-c2/guest.sh), which reaches the
# server at 10.0.2.2 (QEMU user-mode networking). The images are public Alpine tags pulled
# through Google's mirror of Docker Hub; the agent pulls each the first time a replica needs it.
#
# Commands:  guest.sh setup-root | learn <reference> | agent <node> <server host:port>
#            guest.sh containers | kill-agent | start-agent | logs
#
# Every command prints `ok: ...` for what it did, or `FAIL: ...` and exits 1 (`containers`
# prints its listing alone).

BIN=/home/cube/bin
STATE=/root/state
LOG=/root/log
ARGS=/root/agent.args
# Root's id range for Zigbox's full map; cube's is 100000:65536 (src/demo_c2_vms.zig).
ROOT_RANGE=200000:65536

export HOME=/root
# Zigbox asks the caller's systemd user manager for a scope per container; root's is
# user@0.service, which `setup-root` starts by lingering root.
export XDG_RUNTIME_DIR=/run/user/0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus
# Docker Hub images come through Google's mirror, as in Zigbox's CI; the agent passes this on to
# Zigbox's pull (docs/agent.md, "Images").
export ZBX_REGISTRY_MIRRORS=mirror.gcr.io

fail() {
    echo "FAIL: $*"
    exit 1
}

ok() { echo "ok: $*"; }

agent_pid() { pgrep -f "^$BIN/zcube-agent --runtime"; }

start_agent() {
    # The arguments were written by `agent`; word splitting is wanted (none holds a space).
    # shellcheck disable=SC2046
    setsid "$BIN/zcube-agent" $(cat "$ARGS") >>"$LOG/agent.log" 2>&1 </dev/null &
    sleep 1
    agent_pid >/dev/null || fail "the agent exited at once: $(tail -20 "$LOG/agent.log")"
}

# Root gets a subordinate range (the full id map) and a systemd user manager with its bus.
cmd_setup_root() {
    [ "$(id -u)" -eq 0 ] || fail "setup-root runs as root"
    for file in /etc/subuid /etc/subgid; do
        grep -q "^root:" "$file" || echo "root:$ROOT_RANGE" >>"$file" || fail "append to $file"
    done
    loginctl enable-linger root || fail "loginctl enable-linger root"
    tries=0
    while [ ! -S "$XDG_RUNTIME_DIR/bus" ]; do
        tries=$((tries + 1))
        [ $tries -le 300 ] || fail "no bus at $XDG_RUNTIME_DIR/bus within 30 s"
        sleep 0.1
    done
    ok "root has $(grep '^root:' /etc/subuid) in /etc/subuid and a bus at $XDG_RUNTIME_DIR/bus"
}

# The tree digest Zigbox gives an image on this guest, from a pull into a scratch store that is
# deleted after: the node's own store stays as it was, so its agent pulls for real.
cmd_learn() {
    [ $# -eq 1 ] || fail "usage: guest.sh learn <reference>"
    scratch=/root/learn
    rm -rf "$scratch"
    mkdir -p "$scratch/data" "$scratch/cache" "$scratch/state"
    out=$(XDG_DATA_HOME="$scratch/data" XDG_CACHE_HOME="$scratch/cache" \
        XDG_STATE_HOME="$scratch/state" "$BIN/zbx" pull --output json "$1" 2>"$scratch.err")
    status=$?
    rm -rf "$scratch"
    [ $status -eq 0 ] || fail "zbx pull $1 exited $status: $(tail -5 "$scratch.err")"
    tree=$(printf '%s' "$out" | sed -n 's/.*"tree":"\(b3:[0-9a-f]\{64\}\)".*/\1/p')
    [ -n "$tree" ] || fail "zbx pull $1 printed no tree"
    echo "tree $tree"
}

cmd_agent() {
    [ $# -eq 2 ] || fail "usage: guest.sh agent <node> <server>"
    mkdir -p "$STATE" "$LOG"
    echo "--runtime zigbox --node $1 --server $2 --state-dir $STATE --cpu-millis 2000" \
        "--memory-bytes 1073741824 --verbose" >"$ARGS"
    start_agent
    ok "zcube-agent --runtime zigbox --node $1 --server $2 (pid $(agent_pid))"
}

# One line per container supervisor (`zcube-agent supervise-zigbox <launch directory>`): its pid,
# its launch directory and the pids of its children, sorted. The host compares two listings.
cmd_containers() {
    for pid in $(pgrep -f "^$BIN/zcube-agent supervise-zigbox" | sort -n); do
        dir=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | awk '{ print $3 }')
        [ -n "$dir" ] || continue
        children=$(pgrep -P "$pid" | sort -n | tr '\n' ' ')
        echo "supervisor $pid $(basename "$dir") children ${children% }"
    done
}

# SIGKILL of the agent alone: its supervisors lead sessions of their own and keep running.
cmd_kill_agent() {
    pid=$(agent_pid) || fail "no agent to kill"
    kill -KILL $pid
    tries=0
    while agent_pid >/dev/null; do
        tries=$((tries + 1))
        [ $tries -le 100 ] || fail "the agent did not die on SIGKILL within 10 s"
        sleep 0.1
    done
    ok "kill -9 of the agent (pid $pid)"
}

cmd_start_agent() {
    [ -f "$ARGS" ] || fail "no $ARGS: run guest.sh agent first"
    agent_pid >/dev/null && fail "an agent is already running (pid $(agent_pid))"
    start_agent
    ok "the agent started again on $STATE (pid $(agent_pid))"
}

cmd_logs() {
    echo "---- agent.log (last 60 lines) ----"
    tail -60 "$LOG/agent.log" 2>/dev/null
    for log in "$STATE"/containers/*/*.log; do
        [ -f "$log" ] || continue
        echo "---- $log ----"
        tail -10 "$log"
    done
    echo "---- processes ----"
    ps -eo pid,ppid,etime,args | grep -E 'zcube|zbx|sleep' | grep -v grep
}

main() {
    command=$1
    shift
    case "$command" in
        setup-root) cmd_setup_root ;;
        learn) cmd_learn "$@" ;;
        agent) cmd_agent "$@" ;;
        containers) cmd_containers ;;
        kill-agent) cmd_kill_agent ;;
        start-agent) cmd_start_agent ;;
        logs) cmd_logs ;;
        *) fail "unknown command $command" ;;
    esac
}

main "$@"
