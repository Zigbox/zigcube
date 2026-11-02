#!/usr/bin/env bash
# Why this is shell: it is one `kill -9` of a process tree found from pid files; a Zig program
# would add nothing the shell does not already say in two lines.
#
# usage: demo/kill-node.sh <node>
#
# Kills the node's agent and every container under it with SIGKILL, as a power cut would: the
# agent cannot revoke its lease, which then runs out after its ttl (10 s by default). What the
# control plane does about a node whose lease ran out is the node controller's job, not this script's.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
run=$root/demo/run
node=${1:?usage: demo/kill-node.sh <node>}

if [ ! -d "$run/$node" ]; then
    echo "demo/kill-node.sh: no node '$node' under demo/run/; run demo/up.sh first" >&2
    exit 1
fi

# The agent first, so it cannot restart anything; then each supervisor's command (the container),
# then the supervisor. A supervisor killed first would leave its command running.
pkill -9 -f "[z]cube-agent .*--state-dir $run/$node( |\$)" || true
for sup in $(pgrep -f "[z]cube-agent supervise $run/$node/" || true); do
    pkill -9 -P "$sup" || true
    kill -9 "$sup" 2>/dev/null || true
done
rm -f "$run/$node.pid"
echo "killed $node"
