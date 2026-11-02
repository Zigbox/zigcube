#!/usr/bin/env bash
# Why this is shell: it only kills what demo/up.sh started and deletes its directory; it must work
# when nothing else does (no build, no server), so it depends on nothing but coreutils.
#
# usage: demo/down.sh
#
# Kills the agents, their containers and the server, removes demo/run/, and stops the throwaway
# Postgres only if demo/up.sh started it. Safe to run twice, or with nothing running.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
run=$root/demo/run

if [ ! -d "$run" ]; then
    echo "down: nothing to stop"
    exit 0
fi

# Agents and supervisors first, so nothing restarts a container; then the server.
pkill -9 -f "[z]cube-agent .*--state-dir $run/" || true
for sup in $(pgrep -f "[z]cube-agent supervise $run/" || true); do
    pkill -9 -P "$sup" || true
    kill -9 "$sup" 2>/dev/null || true
done
if [ -e "$run/server.pid" ]; then
    kill -9 "$(cat "$run/server.pid")" 2>/dev/null || true
fi
if [ -e "$run/started-postgres" ]; then
    (cd "$root" && zig build pg-down) >/dev/null 2>&1 || true
fi
rm -rf "$run"
echo "down: stopped"
