#!/bin/sh
# `zig build local-smoke`: zcube local up/down as a person would use them (slice 7.6). It runs the
# installed zcube beside zcube-server and zcube-agent, in a directory of its own, and kills
# everything it started even on failure. It is not `demo-c0`.
# Usage: local_smoke.sh <bin dir>
set -u
bin="$1"
dir=$(mktemp -d /tmp/zcube-local-smoke.XXXXXX)
export ZCUBE_LOCAL_DIR="$dir/local"
unset ZCUBE_SERVER

cleanup() {
    "$bin/zcube" local down >/dev/null 2>&1
    # Containers are left running by `down` on purpose; this test owns them, so it ends them.
    pkill -9 -f "$dir" 2>/dev/null
    rm -rf "$dir"
}
trap cleanup EXIT

fail() {
    echo "local-smoke: FAIL: $1"
    [ -f "$ZCUBE_LOCAL_DIR/server.log" ] && tail -n 20 "$ZCUBE_LOCAL_DIR/server.log"
    [ -f "$ZCUBE_LOCAL_DIR/agent.log" ] && tail -n 20 "$ZCUBE_LOCAL_DIR/agent.log"
    exit 1
}

cat >"$dir/hello.zon" <<'EOF'
.{ .name = "hello", .image = "b3:51aa9c03", .replicas = 3, .command = .{ "sleep", "300" } }
EOF

replicas_running() { # prints how many replicas are running
    "$bin/zcube" get replicas 2>/dev/null | grep -c ' running '
}
wait_replicas() {
    n=0
    while [ $n -lt 200 ]; do
        [ "$(replicas_running)" = 3 ] && return 0
        sleep 0.1
        n=$((n + 1))
    done
    return 1
}
supervisors() { pgrep -f "zcube-agent supervise" | wc -l; }

out=$("$bin/zcube" local up) || fail "up"
echo "$out" | grep -q '^local: up' || fail "first up did not say up: $out"
addr=$(echo "$out" | sed -n 's/^  export ZCUBE_SERVER=//p')
[ -n "$addr" ] || fail "no address in: $out"
export ZCUBE_SERVER="$addr"
echo "local-smoke: up at $addr"

"$bin/zcube" local up | grep -q '^local: already running' || fail "second up changed things"
"$bin/zcube" apply --yes "$dir/hello.zon" >/dev/null || fail "apply"
wait_replicas || fail "3 replicas did not run"
before=$(supervisors)
echo "local-smoke: 3 replicas running, $before supervisors"

"$bin/zcube" local down | grep -q '^local: stopped' || fail "down"
"$bin/zcube" local up | grep -q '^local: up' || fail "up after down"
wait_replicas || fail "replicas not running after restart"
[ "$(supervisors)" = "$before" ] || fail "supervisors changed: $before -> $(supervisors)"
echo "local-smoke: replicas adopted, not duplicated"

"$bin/zcube" local down | grep -q '^local: stopped' || fail "second down"
"$bin/zcube" local down | grep -q '^local: not running' || fail "down when down"
echo "local-smoke: PASS"
