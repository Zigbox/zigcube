#!/bin/sh
# The guest half of `zig build zigbox-smoke` (src/zigbox_smoke.zig, docs/demos/c2.md): zcube-server,
# zcube-agent --runtime zigbox and real containers, as the ordinary user `cube`. The host half
# copies the binaries in, then calls this script once per stage and fails on a non-zero status.
# Each stage prints `ok: ...` for what it checked, and on failure `FAIL: ...` and the logs.
#
# Run as: guest.sh <stage>   (stages in the order of `main` at the bottom)

PORT=7070
NODE=smoke
BIN=$HOME/bin
STATE=$HOME/state
LOG=$HOME/log
API="http://127.0.0.1:$PORT"

# The locked trees come from Zigbox's own lock file (src/testing/vm/zbx.lock), which its CI checks.
ALPINE_TREE=b3:2e478596e56b3c0f1748d14e505d5d289ead0bb0526cbd53b325baff01afe599
ALPINE_REF=alpine:3.20@sha256:c64c687cbea9300178b30c95835354e34c4e4febc4badfe27102879de0483b5e
PYTHON_TREE=b3:2ef2776fb138a7b7010d46af46cb15b338dff81ce3c2d8927e8bbe3fb6db0897
PYTHON_REF=python:3.12-slim@sha256:6d2b0577e6d1632f077331de8e4780535f54839d163ded7abb4b7dd37b5d37ac
# Names an image the registry has, but not with this tree: the pull must be refused.
WRONG_TREE=b3:00000000000000000000000000000000000000000000000000000000000000aa
# Names no image at all.
UNKNOWN_TREE=b3:00000000000000000000000000000000000000000000000000000000000000bb

# Zigbox asks the user's systemd for a scope per container: it needs this session's variables.
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export ZBX_REGISTRY_MIRRORS=mirror.gcr.io

fail() {
    echo "FAIL: $*"
    for f in "$LOG"/*.log; do
        echo "--- $f"
        tail -n 25 "$f"
    done
    exit 1
}

ok() { echo "ok: $*"; }

# until <seconds> <what> <command...>: retries the command each second.
until_ok() {
    limit=$1
    what=$2
    shift 2
    n=0
    while ! "$@" >/dev/null 2>&1; do
        n=$((n + 1))
        [ "$n" -le "$limit" ] || fail "timed out after ${limit}s waiting for $what"
        sleep 1
    done
}

api_get() { curl -sf "$API$1"; }

apply() { curl -sf -X POST "$API/v1/apply" -d "$1" >/dev/null || fail "apply $1"; }

# The command of every service, ending in a comment that names it, so `pgrep -f` finds the
# container's PID 1 (the host sees it as an ordinary process).
service_json() { # name tree replicas limits command
    echo "{\"name\":\"$1\",\"image\":\"$2\",\"replicas\":$3,\"limits\":$4,\"command\":$5}"
}

loop_json() { echo "[\"sh\",\"-c\",\"while true; do sleep 1; done # $1\"]"; }

# The pids of a service's containers, one per line.
box_pids() { pgrep -f "do sleep 1; done # $1" | sort -n; }
count() { box_pids "$1" | wc -l; }

# `replica status exit_kind diagnostic_code` for every observed replica of a service.
observed() {
    api_get "/v1/list?prefix=/observed/$NODE/" | python3 -c '
import json, sys
for kv in json.load(sys.stdin)["kvs"]:
    v = kv["value"]
    if v["replica"].startswith(sys.argv[1] + "-"):
        print(v["replica"], v["status"], (v.get("exit") or {}).get("kind", "-"),
              (v.get("diagnostic") or {}).get("code", "-"))
' "$1"
}

running_count() { observed "$1" | grep -c ' running '; }
has_code() { observed "$1" | grep -q " $2\$"; }
has_exit() { observed "$1" | grep -q " stopped $2 "; }
two_boxes() { [ "$(count box)" -eq 2 ] && [ "$(running_count box)" -eq 2 ]; }

start_agent() {
    setsid "$BIN/zcube-agent" --runtime zigbox --node $NODE --server 127.0.0.1:$PORT \
        --state-dir "$STATE" --cpu-millis 2000 --memory-bytes 1073741824 \
        --images "$HOME/images.zon" >>"$LOG/agent.log" 2>&1 </dev/null &
}

agent_pid() { pgrep -f "^$BIN/zcube-agent --runtime"; }

stage_setup() {
    mkdir -p "$STATE" "$LOG"
    cat >"$HOME/images.zon" <<EOF
.{ .images = .{
    .{ .digest = "$ALPINE_TREE", .reference = "$ALPINE_REF" },
    .{ .digest = "$PYTHON_TREE", .reference = "$PYTHON_REF" },
    .{ .digest = "$WRONG_TREE", .reference = "$ALPINE_REF" },
} }
EOF
    "$BIN/zbx" doctor >"$LOG/doctor.log" 2>&1 || fail "zbx doctor"
    setsid "$BIN/zcube-server" --listen 127.0.0.1:$PORT --store memory --quiet \
        >"$LOG/server.log" 2>&1 </dev/null &
    until_ok 30 "the server" api_get /v1/status
    start_agent
    ok "server and agent (--runtime zigbox) are up"
}

stage_replicas() {
    # 128 MiB and half a CPU. The first start pulls alpine through the mirror.
    apply "$(service_json box $ALPINE_TREE 2 '{"cpu_millis":500,"memory_bytes":134217728}' "$(loop_json box)")"
    until_ok 240 "2 box replicas running" two_boxes
    ok "2 replicas of an image pulled from $ALPINE_REF run as 2 containers"
    for pid in $(box_pids box); do
        scope=$(sed -n 's/^0:://p' /proc/"$pid"/cgroup)
        memory=$(cat "/sys/fs/cgroup$scope/memory.max")
        cpu=$(cat "/sys/fs/cgroup$scope/cpu.max")
        [ "$memory" = 134217728 ] || fail "pid $pid: memory.max is $memory, not 134217728"
        case "$cpu" in "50000 "*) ;; *) fail "pid $pid: cpu.max is '$cpu', not 50000 ..." ;; esac
        ok "pid $pid: cgroup memory.max $memory, cpu.max $cpu"
        links=$(awk -F: 'NR > 2 { gsub(/ /, "", $1); print $1 }' /proc/"$pid"/net/dev | tr '\n' ' ')
        [ "$links" = "lo " ] || fail "pid $pid: network interfaces are '$links', not only lo"
        ok "pid $pid: the only network interface is lo"
    done
}

stage_kill() {
    old=$(box_pids box | head -n 1)
    keep=$(box_pids box | tail -n 1)
    kill -9 "$old"
    replaced() { two_boxes && ! box_pids box | grep -qx "$old"; }
    until_ok 90 "kill -9 of $old to be replaced" replaced
    box_pids box | grep -qx "$keep" || fail "the other container ($keep) was disturbed"
    ok "kill -9 of container pid $old: replaced, the other (pid $keep) untouched"
}

stage_restart() {
    before=$(box_pids box | tr '\n' ' ')
    supervisors=$(pgrep -fc 'zcube-agent supervise-zigbox')
    kill -TERM "$(agent_pid)"
    gone() { ! agent_pid; }
    until_ok 30 "the agent to stop" gone
    [ "$(count box)" -eq 2 ] || fail "stopping the agent stopped containers"
    start_agent
    sleep 15
    after=$(box_pids box | tr '\n' ' ')
    [ "$before" = "$after" ] || fail "containers changed over an agent restart: '$before' then '$after'"
    [ "$(pgrep -fc 'zcube-agent supervise-zigbox')" -eq "$supervisors" ] || fail "supervisors changed"
    until_ok 30 "adopted replicas observed running" two_boxes
    ok "agent restart adopted '$before' with no duplicates ($supervisors supervisors)"
}

# The exit kinds the controller acted on for a service's replicas, from `/decisions/`: the
# durable witness. The replica controller deletes an ended replica's observed record at once and
# replaces it, so `stopped oom` is observed for an instant that a poll can miss, but the decision
# that replaces it keeps what justified it in `cause_evidence` (docs/keys.md).
decided_exits() {
    api_get "/v1/list?prefix=/decisions/" | python3 -c '
import json, sys
for kv in json.load(sys.stdin)["kvs"]:
    v = kv["value"]
    key = (v.get("cause") or {}).get("key", "")
    if "/observed/" + sys.argv[1] + "/" + sys.argv[2] + "-" in key:
        print(v.get("action"), key, ((v.get("cause_evidence") or {}).get("exit") or {}).get("kind", "-"))
' "$NODE" "$1"
}

# True once the hog was seen to end as oom, observed or decided.
hog_oom() { has_exit hog oom || decided_exits hog | grep -q ' oom$'; }

# What the oom stage shows when the hog is not seen to end as oom, in one place of the log: the
# runtime's own records (Zigbox keeps at most 32 and prunes the oldest), what the agent observed,
# and what the controller decided.
oom_diagnostics() {
    echo "--- oom stage diagnostics"
    runs="${XDG_STATE_HOME:-$HOME/.local/state}/zbx/runs"
    echo "zbx run records: $(ls "$runs" 2>/dev/null | wc -l) in $runs"
    "$BIN/zbx" ps --all --output json 2>&1 | head -c 6000
    echo "observed hog: $(observed hog | tr '\n' ';')"
    echo "observed box: $(observed box | tr '\n' ';')"
    echo "decided hog: $(decided_exits hog | sort | uniq -c | tr '\n' ';')"
    echo "hog containers now: $(pgrep -fc 'tail /dev/zero')"
    for f in "$runs"/hog-*.zon; do
        [ -e "$f" ] && { echo "--- $f"; tail -n 40 "$f"; }
    done
    dmesg 2>/dev/null | grep -i -E 'out of memory|killed process' | tail -n 6
}

stage_oom() {
    # busybox tail keeps a line with no newline in memory: /dev/zero fills the 32 MiB limit.
    # The sleep paces the restarts (Zigcube has no backoff): unpaced, CI's run of ac94f8a made 47
    # hog replicas in 14 s and Zigbox, which keeps at most 32 run records and prunes the oldest,
    # live ones included, pruned box's, so box showed `starting`. `exec` makes tail PID 1.
    apply "$(service_json hog $ALPINE_TREE 1 '{"memory_bytes":33554432}' \
        '["sh","-c","sleep 4; exec tail /dev/zero"]')"
    n=0
    until hog_oom; do
        n=$((n + 1))
        if [ "$n" -gt 240 ]; then
            oom_diagnostics
            fail "timed out after 120s waiting for hog to end as oom"
        fi
        sleep 0.5
    done
    ok "a container past its memory limit ends as oom ($(observed hog | tr '\n' ';') $(decided_exits hog | head -n 1))"
    two_boxes || fail "box was disturbed by the oom stage: $(observed box | tr '\n' ';')"
    curl -sf -X DELETE "$API/v1/services/hog" >/dev/null || fail "delete hog"
}

stage_refusals() {
    apply "$(service_json wrong $WRONG_TREE 1 '{}' "$(loop_json wrong)")"
    until_ok 120 "wrong to be refused" has_code wrong ZC-E0511
    ok "a pull whose tree is not the locked one is refused (ZC-E0511), the replica held"
    apply "$(service_json unknown $UNKNOWN_TREE 1 '{}' "$(loop_json unknown)")"
    until_ok 60 "unknown to be refused" has_code unknown ZBX-E0410
    ok "a digest the node cannot pull is held with ZBX-E0410"
    two_boxes || fail "box was disturbed by the refusals: $(observed box | tr '\n' ';')"
    curl -sf -X DELETE "$API/v1/services/wrong" >/dev/null || fail "delete wrong"
    curl -sf -X DELETE "$API/v1/services/unknown" >/dev/null || fail "delete unknown"
}

stage_scale0() {
    # A larger image, so the pull is still running when the service goes away.
    apply "$(service_json big $PYTHON_TREE 1 '{}' '["sleep","1000"]')"
    started() { [ -d "$STATE/zigbox" ] && pgrep -f 'supervise-zigbox.*big-' >/dev/null; }
    until_ok 60 "big's supervisor to start" started
    curl -sf -X DELETE "$API/v1/services/big" >/dev/null || fail "delete big"
    sleep 20
    agent_pid >/dev/null || fail "the agent died when a service was removed during a pull"
    two_boxes || fail "box was disturbed by removing big: $(count box) processes, observed:" \
        "$(observed box | tr '\n' ';')" "processes:" \
        "$(ps -eo pid,etime,args | grep -E 'zcube|# (box|big)' | grep -v grep)" \
        "launch box-5: $(ls -l "$STATE"/zigbox/box-5 | tr '\n' ';') supervisor.pid: $(cat "$STATE"/zigbox/box-5/supervisor.pid)" \
        "zbx ps: $("$BIN/zbx" ps --all 2>&1 | tr '\n' ';')"
    ok "removing a service during its pull leaves the agent and box running"
}

main() {
    stage=$1
    mkdir -p "$LOG"
    "stage_$stage" || fail "stage $stage"
}

main "$@"
