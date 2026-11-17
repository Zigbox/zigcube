#!/usr/bin/env bash
# Tests zigcube.sh and fault.sh on this host with the real executables, through a fake systemctl
# that starts each unit's ExecStart as a background process: a server on SQLite with --listen
# (mTLS), its CA and admin client certificate, a node certificate, an agent joined over TLS,
# idempotent re-runs, `fault.sh pause server` (a client times out, then succeeds after resume),
# and `fault.sh kill agent` (its containers' supervisors live on; the agent is started again).
# Partitions need iptables and Postgres needs its server: neither is tested here (README.md).
#
# usage: test-recipe.sh ZCUBE ZCUBE_SERVER ZCUBE_AGENT ZCUBE_JEPSEN_CLIENT
# Both scripts require root, so as any other user this test says so and passes without running.

set -euo pipefail

[ $# -eq 4 ] || { echo "usage: test-recipe.sh ZCUBE ZCUBE_SERVER ZCUBE_AGENT CLIENT" >&2; exit 2; }
if [ "$(id -u)" != 0 ]; then
    echo "test-recipe.sh: skipped (zigcube.sh and fault.sh run as root only)"
    exit 0
fi
here=$(cd "$(dirname "$0")" && pwd)
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
zcube=$(abs "$1")
server_exe=$(abs "$2")
agent_exe=$(abs "$3")
client_exe=$(abs "$4")

tmp=$(mktemp -d /tmp/zcube-recipe-test.XXXXXX)
port=$((30000 + $$ % 20000))
fail() {
    echo "test-recipe.sh: FAIL: $*" >&2
    for log in "$tmp"/units/*.log; do [ -f "$log" ] && tail -n 5 "$log" >&2; done
    exit 1
}
cleanup() {
    local pidfile
    for pidfile in "$tmp"/units/*.pid; do
        [ -f "$pidfile" ] || continue
        kill -CONT "$(cat "$pidfile")" 2>/dev/null || true
        kill -KILL "$(cat "$pidfile")" 2>/dev/null || true
    done
    pkill -KILL -f "[z]cube-agent supervise $tmp/" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

# The install layout `zigcube.sh install` makes, from the given executables.
mkdir -p "$tmp/opt/test/bin" "$tmp/opt/test/share/jepsen" "$tmp/units"
ln -s "$zcube" "$tmp/opt/test/bin/zcube"
ln -s "$server_exe" "$tmp/opt/test/bin/zcube-server"
ln -s "$agent_exe" "$tmp/opt/test/bin/zcube-agent"
ln -sfn test "$tmp/opt/current"

# The fake systemctl: each unit's ExecStart, rewritten to the test's directories, run in the
# background with its pid in units/<unit>.pid.
cat > "$tmp/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
units=$TEST_DIR/units
# A killed process this container's init has not reaped is a zombie: not alive.
alive() {
    [ -f "$units/$1.pid" ] || return 1
    local stat
    stat=$(ps -o stat= -p "$(cat "$units/$1.pid")" 2>/dev/null) || return 1
    case $stat in Z*) return 1 ;; *) return 0 ;; esac
}
case $1 in
    daemon-reload) ;;
    is-active) alive "$3" ;;
    show) if alive "$5"; then cat "$units/$5.pid"; else echo 0; fi ;;
    cat) exit 1 ;;
    restart)
        if alive "$2"; then kill -KILL "$(cat "$units/$2.pid")"; fi
        line=$(grep '^ExecStart=' "$TEST_UNIT_SRC/$2.service")
        line=${line#ExecStart=}
        line=${line//\/opt\/zigcube/$ZCUBE_OPT}
        line=${line//\/etc\/zcube/$ZCUBE_ETC}
        # shellcheck disable=SC2086 # The unit's words.
        setsid $line >> "$units/$2.log" 2>&1 < /dev/null &
        echo $! > "$units/$2.pid"
        ;;
    *) echo "fake systemctl: unsupported: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/systemctl"
export TEST_DIR=$tmp TEST_UNIT_SRC=$here ZCUBE_SYSTEMCTL=$tmp/systemctl ZCUBE_OPT=$tmp/opt

on_server() { ZCUBE_ETC=$tmp/server-etc ZCUBE_VAR=$tmp/server-var "$here/zigcube.sh" "$@"; }
on_node() { ZCUBE_ETC=$tmp/node-etc ZCUBE_VAR=$tmp/node-var "$here/zigcube.sh" "$@"; }
mkdir -p "$tmp/server-etc" "$tmp/node-etc" "$tmp/server-var" "$tmp/node-var"
cp "$here/images.zon" "$tmp/node-etc/images.zon"

on_server server "sqlite:$tmp/store.db" "127.0.0.1:$port" || fail "server"
[ -s "$tmp/server-etc/ca.crt" ] || fail "no ca.crt"
[ -s "$tmp/server-etc/client/jepsen.key" ] || fail "no client certificate"
server_pid=$(cat "$tmp/units/zcube-server.pid")
on_server server "sqlite:$tmp/store.db" "127.0.0.1:$port" || fail "server, again"
[ "$(cat "$tmp/units/zcube-server.pid")" = "$server_pid" ] || fail "an unchanged server restarted"

on_server node-cert n1 || fail "node-cert"
cp "$tmp/server-etc/ca.crt" "$tmp/node-etc/ca.crt"
cp "$tmp/server-etc/nodes/n1.crt" "$tmp/node-etc/node.crt"
cp "$tmp/server-etc/nodes/n1.key" "$tmp/node-etc/node.key"
on_node agent n1 "127.0.0.1:$port" 4000 4294967296 || fail "agent"
agent_pid=$(cat "$tmp/units/zcube-agent.pid")
on_node agent n1 "127.0.0.1:$port" 4000 4294967296 || fail "agent, again"
[ "$(cat "$tmp/units/zcube-agent.pid")" = "$agent_pid" ] || fail "an unchanged agent restarted"

etc=$tmp/server-etc
client() {
    "$client_exe" --history "$tmp/history" --process 1 --service s --server "127.0.0.1:$port" \
        --ca "$etc/ca.crt" --cert "$etc/client/jepsen.crt" --key "$etc/client/jepsen.key" "$@"
}
client --op apply --value 2 >/dev/null || fail "apply"
# The agent joins and starts both replicas, each under a supervisor of its own.
tries=0
until [ "$(pgrep -c -f "[z]cube-agent supervise $tmp/node-var/" || true)" = 2 ]; do
    tries=$((tries + 1))
    [ $tries -le 200 ] || fail "two replicas did not start within 20 s"
    sleep 0.1
done

"$here/fault.sh" pause server || fail "pause"
status=0
timeout 3 "$client_exe" --history "$tmp/history" --process 2 --service s --op get \
    --server "127.0.0.1:$port" --ca "$etc/ca.crt" --cert "$etc/client/jepsen.crt" \
    --key "$etc/client/jepsen.key" >/dev/null || status=$?
[ "$status" = 124 ] || fail "a get from a paused server ended with $status, not the timeout"
"$here/fault.sh" resume server || fail "resume"
client --op get >/dev/null || fail "get after resume"

"$here/fault.sh" kill agent || fail "kill agent"
[ "$(pgrep -c -f "[z]cube-agent supervise $tmp/node-var/" || true)" = 2 ] ||
    fail "the replicas' supervisors did not outlive the agent"
on_node agent n1 "127.0.0.1:$port" 4000 4294967296 || fail "agent, after kill"
[ "$(cat "$tmp/units/zcube-agent.pid")" != "$agent_pid" ] || fail "the killed agent not restarted"
client --op get >/dev/null || fail "get after the agent's restart"
echo "test-recipe.sh: PASS"
