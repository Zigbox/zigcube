#!/usr/bin/env bash
# Why this is shell: it starts and supervises a handful of long-lived processes (a server and three
# agents) and waits for them, which is what a shell is for; a Zig program would only wrap
# fork/exec. `zcube local up` (src/cli_local.zig) is the Zig version for one machine and one agent.
#
# usage: demo/up.sh [sqlite|postgres]     (default sqlite)
#
# Starts zcube-server and three zcube-agents (node1..node3) as host processes, state under
# demo/run/. Containers are plain processes under supervisors of their own, so they outlive an
# agent. Stop everything with demo/down.sh; kill one node with demo/kill-node.sh <node>.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
run=$root/demo/run
backend=${1:-sqlite}
addr=127.0.0.1:7070
bin=$root/zig-out/bin

if [ -e "$run/server.pid" ] && kill -0 "$(cat "$run/server.pid")" 2>/dev/null; then
    echo "demo/up.sh: already up (server pid $(cat "$run/server.pid")); run demo/down.sh first" >&2
    exit 1
fi

if [ ! -x "$bin/zcube-server" ] || [ ! -x "$bin/zcube-agent" ] || [ ! -x "$bin/zcube" ]; then
    (cd "$root" && zig build)
fi

mkdir -p "$run"
case $backend in
sqlite) store=sqlite:$run/store.db ;;
postgres)
    (cd "$root" && zig build pg-up) >"$run/pg-up.log" 2>&1
    touch "$run/started-postgres"
    store="postgres:host=127.0.0.1 port=55432 user=zcube dbname=postgres"
    ;;
*)
    echo "usage: demo/up.sh [sqlite|postgres]" >&2
    exit 1
    ;;
esac

"$bin/zcube-server" --listen "$addr" --store "$store" --create-store --state-dir "$run" \
    </dev/null >"$run/server.log" 2>&1 &
echo $! >"$run/server.pid"

for n in 1 2 3; do
    mkdir -p "$run/node$n"
    "$bin/zcube-agent" --node "node$n" --server "$addr" --state-dir "$run/node$n" \
        --cpu-millis 4000 --memory-bytes 8589934592 --images "$root/fixtures/images.zon" \
        </dev/null >"$run/node$n.log" 2>&1 &
    echo $! >"$run/node$n.pid"
done

export ZCUBE_SERVER=$addr
for _ in $(seq 1 100); do
    ready=$("$bin/zcube" get nodes 2>/dev/null | grep -c '^node[123] ' || true)
    [ "$ready" -eq 3 ] && break
    sleep 0.2
done
if [ "$ready" -ne 3 ]; then
    echo "demo/up.sh: the three nodes did not register; see $run/*.log" >&2
    exit 1
fi

cat <<USAGE
up: server $addr ($backend), nodes node1 node2 node3, logs in demo/run/
  export ZCUBE_SERVER=$addr
  zcube get nodes
  zcube apply hello.zon
  demo/kill-node.sh node2     # kill -9 the agent and its containers
  demo/down.sh                # stop everything
USAGE
