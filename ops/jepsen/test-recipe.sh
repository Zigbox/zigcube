#!/usr/bin/env bash
# Tests zigcube.sh and fault.sh on this host with the real executables, through a fake systemctl
# that starts each unit's ExecStart as a background process: a server on a memory store, then on
# Postgres when ZCUBE_RECIPE_POSTGRES holds libpq settings (each must yield its CA, `ca.crt`, and
# a client certificate that CA signed), then on SQLite (`ca-<hash>.crt`) with --listen (mTLS),
# a node certificate, an agent joined over TLS, idempotent re-runs, `fault.sh pause server` (a
# client times out, then succeeds after resume), and `fault.sh kill agent` (its containers'
# supervisors live on; the agent is started again). Partitions need iptables, and postgres.sh a
# Postgres of its own: test-postgres.sh tests that.
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
# Below Linux's ephemeral range (32768 and up), which other tests' connections draw from; the
# memory and Postgres servers take the next two ports.
port=$((20000 + $$ % 3000 * 3))
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

mkdir -p "$tmp/units" "$tmp/unit-dir"

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
# The fake starts the units `zigcube.sh install` installed.
export TEST_DIR=$tmp TEST_UNIT_SRC=$tmp/unit-dir ZCUBE_SYSTEMCTL=$tmp/systemctl ZCUBE_OPT=$tmp/opt

on_server() { ZCUBE_ETC=$tmp/server-etc ZCUBE_VAR=$tmp/server-var "$here/zigcube.sh" "$@"; }
on_node() { ZCUBE_ETC=$tmp/node-etc ZCUBE_VAR=$tmp/node-var "$here/zigcube.sh" "$@"; }
mkdir -p "$tmp/server-etc" "$tmp/node-etc" "$tmp/server-var" "$tmp/node-var"

# A tarball laid out as `zig build dist` lays it out (the executables linked, not copied), its
# SHA-256, and `zigcube.sh install`. Both hosts of this test share the one /opt.
top=zigcube-test-000000000000-dirty-x86_64-linux
pack() {
    rm -rf "$tmp/pack"
    mkdir -p "$tmp/pack/$top/bin" "$tmp/pack/$top/share/jepsen"
    ln -s "$zcube" "$tmp/pack/$top/bin/zcube"
    ln -s "$server_exe" "$tmp/pack/$top/bin/zcube-server"
    ln -s "$agent_exe" "$tmp/pack/$top/bin/zcube-agent"
    ln -s "$client_exe" "$tmp/pack/$top/bin/zcube-jepsen-client"
    local file
    for file in README.md zigcube.sh postgres.sh fault.sh images.zon zcube-server.service \
        zcube-agent.service; do
        cp "$here/$file" "$tmp/pack/$top/share/jepsen/"
    done
    echo "$1" > "$tmp/pack/$top/COMMIT"
    tar -czf "$tmp/$top.tar.gz" -C "$tmp/pack" "$top"
    (cd "$tmp" && sha256sum "$top.tar.gz" > "$top.tar.gz.sha256")
}
on_install() {
    ZCUBE_ETC=$tmp/node-etc ZCUBE_UNIT_DIR=$tmp/unit-dir \
        "$here/zigcube.sh" install "$tmp/$top.tar.gz"
}
pack first
on_install || fail "install"
[ "$(readlink "$tmp/opt/current")" = "$top" ] || fail "install did not point current at $top"
[ -f "$tmp/unit-dir/zcube-agent.service" ] || fail "install did not install the units"
[ -f "$tmp/node-etc/images.zon" ] || fail "install did not install images.zon"
on_install || fail "install, again"
# A second `-dirty` build of one commit has the same name and other bytes: unpacked again.
pack second
on_install || fail "install of another tarball of the same name"
[ "$(cat "$tmp/opt/current/COMMIT")" = second ] || fail "a tarball of another digest not unpacked"
printf 'x' >> "$tmp/$top.tar.gz"
if on_install >/dev/null 2>&1; then fail "a tarball that does not match its SHA-256 installed"; fi

# A store other than SQLite: its CA is `ca.crt`. The server stays up until the next case's
# server.zon differs, when the fake systemctl replaces it.
store_case() {
    local name=$1 store=$2 listen=$3
    local etc_dir=$tmp/$name-etc var_dir=$tmp/$name-var
    mkdir -p "$etc_dir" "$var_dir"
    ZCUBE_ETC=$etc_dir ZCUBE_VAR=$var_dir "$here/zigcube.sh" server "$store" "$listen" ||
        fail "server on $name"
    [ -s "$etc_dir/ca.crt" ] || fail "no ca.crt for $name"
    cmp -s "$etc_dir/ca.crt" "$var_dir/zcube-server/ca.crt" || fail "$name's ca.crt is not ca.crt"
    "$client_exe" --history "$tmp/history-$name" --process 1 --service s --server "$listen" \
        --ca "$etc_dir/ca.crt" --cert "$etc_dir/client/jepsen.crt" \
        --key "$etc_dir/client/jepsen.key" --op apply --value 1 >/dev/null ||
        fail "an apply over mTLS to the $name store"
}
store_case memory memory "127.0.0.1:$((port + 1))"
if [ -n "${ZCUBE_RECIPE_POSTGRES:-}" ]; then
    store_case postgres "postgres:$ZCUBE_RECIPE_POSTGRES" "127.0.0.1:$((port + 2))"
fi

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
