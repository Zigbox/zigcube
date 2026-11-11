#!/bin/sh
# The guest half of `zig build demo-b3` (src/demo_b3.zig, docs/demos/b3.md). The host half boots
# one guest, copies the binaries and this script in, and calls it as root with one command at a
# time. The server runs on the host; this guest runs one `zcube-agent --runtime zigbox` as root
# (as demo-c2's, ops/demo-c2/guest.sh) and a test upstream on its loopback.
#
# Commands:  guest.sh setup-root | learn <reference> | images <tree> <reference>
#            guest.sh agent <node> <server host:port> | restart | upstream | node-addr
#            guest.sh upstream-log | listeners | relay-logs | logs
#
# Every command prints `ok: ...` for what it did, or `FAIL: ...` and exits 1.

BIN=/home/cube/bin
STATE=/root/state
LOG=/root/log
ARGS=/root/agent.args
UPSTREAM_PORT=9090
IMAGES=/root/images.zon
# Root's id range for Zigbox's full map; cube's is 100000:65536 (src/demo_c2_vms.zig).
ROOT_RANGE=200000:65536

export HOME=/root
# Zigbox asks the caller's systemd user manager for a scope per container; root's is
# user@0.service, which `setup-root` starts by lingering root.
export XDG_RUNTIME_DIR=/run/user/0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus

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
# deleted after: the node's own store stays as it was.
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
    [ -f "$IMAGES" ] || fail "no $IMAGES: run guest.sh images first"
    mkdir -p "$STATE" "$LOG"
    echo "--runtime zigbox --node $1 --server $2 --state-dir $STATE --cpu-millis 2000" \
        "--memory-bytes 1073741824 --images $IMAGES --verbose" >"$ARGS"
    start_agent
    sleep 1
    agent_pid >/dev/null || fail "the agent exited at once: $(tail -20 "$LOG/agent.log")"
    ok "zcube-agent --runtime zigbox --node $1 --server $2 (pid $(agent_pid))"
}

# Tells the agent where to pull a tree from (a job names an image by its tree digest only).
cmd_images() {
    [ $# -eq 2 ] || fail "usage: guest.sh images <tree> <reference>"
    printf '.{ .images = .{ .{ .digest = "%s", .reference = "%s" } } }\n' "$1" "$2" >"$IMAGES"
    ok "$IMAGES maps $1 to $2"
}

# The test upstream, on this guest's loopback: every request is logged (method and path) and
# answered with `upstream-ok`. It is what the server's `relays` names as `botpike`.
cmd_upstream() {
    cat >/root/upstream.py <<'PY'
import http.server
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open("/root/upstream.log", "a") as log:
            log.write("GET " + self.path + "\n")
        body = b"upstream-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", 9090), Handler).serve_forever()
PY
    : >/root/upstream.log
    setsid python3 /root/upstream.py >/root/upstream.err 2>&1 </dev/null &
    tries=0
    until curl -s -m 2 "http://127.0.0.1:$UPSTREAM_PORT/probe" | grep -q upstream-ok; do
        tries=$((tries + 1))
        [ $tries -le 50 ] || fail "the upstream did not answer: $(cat /root/upstream.err)"
        sleep 0.2
    done
    : >/root/upstream.log
    ok "the test upstream answers on 127.0.0.1:$UPSTREAM_PORT"
}

cmd_upstream_log() { cat /root/upstream.log; }

# The address other hosts reach this guest at (the job must not reach it).
cmd_node_addr() {
    addr=$(ip -4 -o addr show scope global | awk '{print $4}' | head -1 | cut -d/ -f1)
    [ -n "$addr" ] || fail "no global address"
    echo "$addr"
}

# What listens in the guest's own network namespace: a job's relay must not.
cmd_listeners() { ss -ltnH; }

cmd_relay_logs() {
    for log in "$STATE"/containers/*/relay.log; do
        [ -f "$log" ] || continue
        echo "---- $log ----"
        cat "$log"
    done
    true
}

cmd_logs() {
    echo "---- agent.log (last 40 lines) ----"
    tail -40 "$LOG/agent.log" 2>/dev/null
    cmd_relay_logs
    echo "---- upstream.log ----"
    cat /root/upstream.log 2>/dev/null
    echo "---- processes ----"
    ps -eo pid,etime,args | grep -E 'zcube|zbx' | grep -v grep
}

main() {
    command=$1
    shift
    case "$command" in
        setup-root) cmd_setup_root ;;
        learn) cmd_learn "$@" ;;
        images) cmd_images "$@" ;;
        agent) cmd_agent "$@" ;;
        restart) cmd_restart ;;
        upstream) cmd_upstream ;;
        upstream-log) cmd_upstream_log ;;
        node-addr) cmd_node_addr ;;
        listeners) cmd_listeners ;;
        relay-logs) cmd_relay_logs ;;
        logs) cmd_logs ;;
        *) fail "unknown command $command" ;;
    esac
}

main "$@"
