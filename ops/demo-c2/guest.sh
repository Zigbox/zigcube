#!/bin/sh
# The guest half of `zig build demo-c2` (src/demo_c2.zig, docs/demos/c2.md, "demo-c2"). The host
# half boots four guests, copies the binaries and this script in, and calls it with one command at
# a time. The server runs on the host; this guest runs one `zcube-agent --runtime zigbox` as the
# ordinary user `cube`, which reaches the server at 10.0.2.2 (QEMU user-mode networking) and serves
# its peers on port 7071, which the host forwards from a port of its own.
#
# Run as cube:  guest.sh agent <node> <server host:port> <advertised host:port>
#               guest.sh restart | fault-on | fault-off | learn <reference> | store-empty
#               guest.sh fetch-logs <pattern> | logs
# Run as root:  guest.sh block-registry
#
# Every command prints `ok: ...` for what it did, or `FAIL: ...` and exits 1.

BIN=/home/cube/bin
STATE=/home/cube/state
LOG=/home/cube/log
ARGS=/home/cube/agent.args
PEER_PORT=7071

# Zigbox asks the user's systemd for a scope per container: it needs this session's variables.
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
# Docker Hub images (step 3's Alpine) come through Google's mirror, as in Zigbox's CI.
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
}

cmd_agent() {
    [ $# -eq 3 ] || fail "usage: guest.sh agent <node> <server> <advertised>"
    mkdir -p "$STATE/faults" "$LOG"
    echo "--runtime zigbox --node $1 --server $2 --state-dir $STATE --cpu-millis 2000" \
        "--memory-bytes 1073741824 --peer-listen 0.0.0.0:$PEER_PORT --peer-advertise $3" \
        "--verbose" >"$ARGS"
    start_agent
    sleep 1
    agent_pid >/dev/null || fail "the agent exited at once: $(tail -20 "$LOG/agent.log")"
    ok "zcube-agent --runtime zigbox --node $1 --server $2 --peer-advertise $3 (pid $(agent_pid))"
}

# Stops the agent (its containers and their supervisors keep running) and starts it again, so a
# test fault written since is read (the peer server reads it once, at its start).
cmd_restart() {
    pid=$(agent_pid) || fail "no agent to restart"
    kill -TERM $pid
    tries=0
    while agent_pid >/dev/null; do
        tries=$((tries + 1))
        [ $tries -le 100 ] || fail "the agent did not stop on SIGTERM within 10 s"
        sleep 0.1
    done
    start_agent
    sleep 1
    agent_pid >/dev/null || fail "the agent exited at once: $(tail -20 "$LOG/agent.log")"
    ok "the agent restarted (pid $pid, now $(agent_pid))"
}

cmd_fault_on() {
    mkdir -p "$STATE/faults"
    : >"$STATE/faults/peer-corrupt"
    ok "test fault $STATE/faults/peer-corrupt written"
}

cmd_fault_off() {
    rm -f "$STATE/faults/peer-corrupt"
    ok "test fault removed"
}

# The tree digest Zigbox gives an image on this guest, from a pull into a scratch store that is
# deleted after: the node's own store stays as it was.
cmd_learn() {
    [ $# -eq 1 ] || fail "usage: guest.sh learn <reference>"
    scratch=/home/cube/learn
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

# The node's own Zigbox store holds no tree (before its agent first starts).
cmd_store_empty() {
    store=/home/cube/.local/share/zbx
    if [ -d "$store" ] && [ -n "$(find "$store" -type f | head -1)" ]; then
        fail "the store $store is not empty"
    fi
    ok "the node's Zigbox store is empty"
}

# Every fetch log line that matches the pattern, prefixed with its container.
cmd_fetch_logs() {
    [ $# -eq 1 ] || fail "usage: guest.sh fetch-logs <pattern>"
    for log in "$STATE"/containers/*/fetch.log; do
        [ -f "$log" ] || continue
        name=$(basename "$(dirname "$log")")
        grep -e "$1" "$log" | sed "s|^|$name: |"
    done
    true
}

cmd_logs() {
    echo "---- agent.log (last 40 lines) ----"
    tail -40 "$LOG/agent.log" 2>/dev/null
    for log in "$STATE"/containers/*/fetch.log; do
        [ -f "$log" ] || continue
        echo "---- $log ----"
        tail -10 "$log"
    done
    echo "---- processes ----"
    ps -eo pid,etime,args | grep -E 'zcube|zbx' | grep -v grep
}

# As root: drop every outbound TCP connection except to the host (10.0.2.2: the server and the
# peers) and loopback, so neither GHCR nor the Docker Hub mirror can be reached, then show it.
cmd_block_registry() {
    [ "$(id -u)" -eq 0 ] || fail "block-registry runs as root"
    nft add table inet demo_c2 || fail "nft add table"
    nft add chain inet demo_c2 out '{ type filter hook output priority 0; policy accept; }' ||
        fail "nft add chain"
    nft add rule inet demo_c2 out oifname lo accept || fail "nft rule lo"
    nft add rule inet demo_c2 out ip daddr 10.0.2.2 accept || fail "nft rule host"
    nft add rule inet demo_c2 out meta l4proto tcp drop || fail "nft rule drop"
    nft add rule inet demo_c2 out meta l4proto udp udp dport != 53 drop || fail "nft rule udp"
    nft list table inet demo_c2
    for url in https://ghcr.io/v2/ https://mirror.gcr.io/v2/; do
        if curl -m 10 -sS -o /dev/null "$url" 2>/tmp/curl.err; then
            fail "curl $url succeeded through the rule"
        fi
        echo "curl -m 10 $url: $(cat /tmp/curl.err)"
    done
    ok "registry access from this guest is blocked; 10.0.2.2 is still reachable"
}

main() {
    command=$1
    shift
    case "$command" in
        agent) cmd_agent "$@" ;;
        restart) cmd_restart ;;
        fault-on) cmd_fault_on ;;
        fault-off) cmd_fault_off ;;
        learn) cmd_learn "$@" ;;
        store-empty) cmd_store_empty ;;
        fetch-logs) cmd_fetch_logs "$@" ;;
        logs) cmd_logs ;;
        block-registry) cmd_block_registry ;;
        *) fail "unknown command $command" ;;
    esac
}

main "$@"
