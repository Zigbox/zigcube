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
# The peer stages (slice 8): agent A is $NODE above, agent B has a Zigbox store and state of its own.
NODE_B=peerb
PEER_A=127.0.0.1:7081
PEER_B=127.0.0.1:7082
B_DIR=$HOME/b

# The locked trees come from Zigbox's own lock file (src/testing/vm/zbx.lock), which its CI checks.
ALPINE_TREE=b3:2e478596e56b3c0f1748d14e505d5d289ead0bb0526cbd53b325baff01afe599
ALPINE_REF=alpine:3.20@sha256:c64c687cbea9300178b30c95835354e34c4e4febc4badfe27102879de0483b5e
PYTHON_TREE=b3:2ef2776fb138a7b7010d46af46cb15b338dff81ce3c2d8927e8bbe3fb6db0897
PYTHON_REF=python:3.12-slim@sha256:6d2b0577e6d1632f077331de8e4780535f54839d163ded7abb4b7dd37b5d37ac
PY13_TREE=b3:2ec6b79d8d9fb965b5c2ae195d7e41754b4fe0c7b835831f12cfdb18800f1f81
PY13_REF=python:3.13-slim@sha256:fea139ecc0ab98360ead50b38872df6d42cf3503bec83215461224cbef0c8269
MEMCACHED_TREE=b3:6af1ea2d0c60bf995daf058a95ad4df25c3b43b2fac92f2cc8ffb46b4f4e2b08
MEMCACHED_REF=memcached:alpine@sha256:9057793717e87e054636eaf06cf8ec2792a3ad164ad9e8bcae1e90241ea73fb0
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
# `source` (the OCI reference the tree is pulled from) is left out when $6 is empty: that service
# relies on its tree being in the node's store already.
service_json() { # name tree replicas limits command [source]
    src=""
    [ -n "${6:-}" ] && src=",\"source\":\"$6\""
    echo "{\"name\":\"$1\",\"image\":\"$2\",\"replicas\":$3,\"limits\":$4,\"command\":$5$src}"
}

loop_json() { echo "[\"sh\",\"-c\",\"while true; do sleep 1; done # $1\"]"; }

# The pids of a service's containers, one per line.
box_pids() { pgrep -f "do sleep 1; done # $1" | sort -n; }
count() { box_pids "$1" | wc -l; }

# `replica status exit_kind diagnostic_code` for every observed replica of a service.
observed() {
    api_get "/v1/list?prefix=/observed/${ON:-$NODE}/" | python3 -c '
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
        --peer-listen $PEER_A >>"$LOG/agent.log" 2>&1 </dev/null &
}

# Agent B: its own node, state directory and Zigbox store (XDG_DATA_HOME), so what it holds is
# what it fetched. Capacity is large, and A's is not, so a service that asks for more than A has
# left goes to B.
start_agent_b() {
    mkdir -p "$B_DIR/data" "$B_DIR/state" "$B_DIR/agent"
    XDG_DATA_HOME=$B_DIR/data XDG_STATE_HOME=$B_DIR/state \
        setsid "$BIN/zcube-agent" --runtime zigbox --node $NODE_B --server 127.0.0.1:$PORT \
        --state-dir "$B_DIR/agent" --cpu-millis 8000 --memory-bytes 4294967296 \
        --peer-listen $PEER_B >>"$LOG/agent-b.log" 2>&1 </dev/null &
}

agent_pid() { pgrep -f "^$BIN/zcube-agent --runtime"; }

stage_setup() {
    mkdir -p "$STATE" "$LOG"
    "$BIN/zbx" doctor >"$LOG/doctor.log" 2>&1 || fail "zbx doctor"
    setsid "$BIN/zcube-server" --listen 127.0.0.1:$PORT --store memory --quiet \
        >"$LOG/server.log" 2>&1 </dev/null &
    until_ok 30 "the server" api_get /v1/status
    start_agent
    ok "server and agent (--runtime zigbox) are up"
}

stage_replicas() {
    # 128 MiB and half a CPU. The first start pulls alpine through the mirror.
    apply "$(service_json box $ALPINE_TREE 2 '{"cpu_millis":500,"memory_bytes":134217728}' "$(loop_json box)" $ALPINE_REF)"
    until_ok 240 "2 box replicas running" two_boxes
    ok "2 replicas of an image pulled from $ALPINE_REF (the service's source) run as 2 containers"
    # The fallback: no source, and the tree is in the node's store now, so it starts without a pull.
    apply "$(service_json cached $ALPINE_TREE 1 '{}' "$(loop_json cached)")"
    cached_up() { [ "$(running_count cached)" -eq 1 ]; }
    until_ok 90 "the cached replica (no source) running" cached_up
    ok "a service with no source starts from the tree already in the node's store"
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
# replaces it, so `stopped oom` is observed for an instant that a poll can miss. The decision
# that replaces it stays, and names the exit in its `reason` ("hog-3 ran out of memory on
# smoke, so it is being removed": `records.exit_text`). The replica controller does not put the
# exit in `cause_evidence` (docs/keys.md shows it there; `remove_dead` leaves it out), so the
# reason is what is read; an exit that is not `oom` prints `-`.
decided_exits() {
    api_get "/v1/list?prefix=/decisions/" | python3 -c '
import json, sys
for kv in json.load(sys.stdin)["kvs"]:
    v = kv["value"]
    key = (v.get("cause") or {}).get("key", "")
    if "/observed/" + sys.argv[1] + "/" + sys.argv[2] + "-" in key:
        kind = ((v.get("cause_evidence") or {}).get("exit") or {}).get("kind", "-")
        if kind == "-" and " ran out of memory on " in (v.get("reason") or ""):
            kind = "oom"
        print(v.get("action"), key, kind)
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
        '["sh","-c","sleep 4; exec tail /dev/zero"]' $ALPINE_REF)"
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
    apply "$(service_json wrong $WRONG_TREE 1 '{}' "$(loop_json wrong)" $ALPINE_REF)"
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
    apply "$(service_json big $PYTHON_TREE 1 '{}' '["sleep","1000"]' $PYTHON_REF)"
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

# ---- Peer fetch (C2 slice 8, M4): agent B gets images from agent A --------------------------

now_ms() { echo $(($(date +%s) * 1000)); }

# `registry_bytes cached_bytes peer_bytes peers` of the newest /pulls record of $1 (node) for
# tree $2 finished at or after $3 (ms), from /v1/stats/pull, which is what the agent published
# from the container's pull.json (it removes the file once stored). Nothing if there is none.
pull_record() {
    api_get "/v1/stats/pull?node=$1&limit=100" | python3 -c '
import json, sys
tree, since = sys.argv[1], int(sys.argv[2])
for p in json.load(sys.stdin)["pulls"]:
    if tree.startswith(p["tree"]) and p["finished_at_ms"] >= since:
        peers = ",".join("%s=%d" % (q["peer"], q["bytes"]) for q in p["peer_bytes"])
        print(p["registry_bytes"], p["cached_bytes"], sum(q["bytes"] for q in p["peer_bytes"]),
              peers or "-")
        break
' "$2" "$3"
}

# Waits for the record, then prints it to the log and the globals REG CACHED PEER and PEERS.
await_pull() { # tree since
    have_pull() { [ -n "$(pull_record $NODE_B "$1" "$2")" ]; }
    until_ok 120 "the pull record of $1 on $NODE_B" have_pull "$1" "$2"
    set -- "$(pull_record $NODE_B "$1" "$2")"
    # shellcheck disable=SC2086
    set -- $1
    REG=$1 CACHED=$2 PEER=$3 PEERS=$4
}

# True when node $1's summary lists tree $2 and a peer address.
holds_tree() {
    short=$(echo "$2" | cut -c1-11)
    api_get "/v1/list?prefix=/node-store/$1" | grep -q "$short" || return 1
    api_get "/v1/list?prefix=/node-store/$1" | grep -q '127.0.0.1:70'
}

# The log of the newest container directory of service $1 on B.
fetch_log_of() { ls -t "$B_DIR"/agent/containers/*"$1"*/fetch.log 2>/dev/null | head -n 1; }

# What B's state directory holds, for a failure message: the layout and every fetch.log.
dump_b() {
    echo "--- B state: $(cd "$B_DIR/agent" 2>/dev/null && find containers zigbox faults -maxdepth 2 2>/dev/null | head -n 60)"
    for f in "$B_DIR"/agent/containers/*/fetch.log; do
        [ -e "$f" ] && { echo "--- $f"; head -c 800 "$f"; }
    done
}

# A service only B can take: more CPU than A has left (2000 millicores less box's 1000).
only_b() { service_json "$1" "$2" 1 '{"cpu_millis":1200,"memory_bytes":134217728}' "$(sleep_json)" "$3"; }
sleep_json() { echo '["sleep","1000"]'; }

stage_peers_prep() {
    # A pulls both Python images from the registry (B is not up yet, so A is the only node), so
    # that it holds them whole and says so in its summary.
    for pair in "prepone $PYTHON_TREE $PYTHON_REF" "preptwo $PY13_TREE $PY13_REF"; do
        set -- $pair
        apply "$(service_json "$1" "$2" 1 '{"cpu_millis":100,"memory_bytes":134217728}' "$(sleep_json)" "$3")"
    done
    both_up() { [ "$(running_count prepone)" -eq 1 ] && [ "$(running_count preptwo)" -eq 1 ]; }
    until_ok 400 "A to run both Python images" both_up
    curl -sf -X DELETE "$API/v1/services/prepone" >/dev/null || fail "delete prepone"
    curl -sf -X DELETE "$API/v1/services/preptwo" >/dev/null || fail "delete preptwo"
    a_holds() { holds_tree $NODE "$PYTHON_TREE" && holds_tree $NODE "$PY13_TREE" &&
        holds_tree $NODE "$ALPINE_TREE"; }
    until_ok 90 "A's summary to list its trees and its peer address" a_holds
    # The supervisor's pull wrote those chunks, not the agent: A's peer server indexes the store
    # when it starts (or at its next write), so restart it to serve what it now holds
    # (decisions/2026-11-04-c2-slice8-review-fixes.md, S3).
    kill -TERM "$(agent_pid)"
    gone_a() { ! agent_pid; }
    until_ok 30 "agent A to stop" gone_a
    start_agent
    until_ok 90 "A's summary again after its restart" a_holds
    ok "agent A ($NODE) holds python:3.12-slim, python:3.13-slim and alpine and says so in /node-store"
}

stage_peers_up() {
    start_agent_b
    node_b_up() { api_get "/v1/list?prefix=/nodes/$NODE_B" | grep -q "$NODE_B"; }
    until_ok 60 "agent B to register" node_b_up
    ok "agent B ($NODE_B, its own Zigbox store under $B_DIR/data) is up beside A"
}

stage_peers_fetch() {
    ON=$NODE_B
    since=$(now_ms)
    apply "$(only_b pyone $PYTHON_TREE $PYTHON_REF)"
    one_up() { [ "$(running_count pyone)" -eq 1 ]; }
    until_ok 240 "pyone to run on $NODE_B" one_up
    await_pull "$PYTHON_TREE" "$since"
    echo "pull record of pyone: registry=$REG cached=$CACHED peer=$PEER peers=$PEERS"
    [ "$PEER" -gt 0 ] || fail "pyone: no bytes came from a peer (registry=$REG peers=$PEERS)" \
        "fetch.log: $(cat "$(fetch_log_of pyone)" 2>&1 | head -c 1500) $(dump_b)"
    [ "$REG" -eq 0 ] || fail "pyone: $REG registry bytes, but A has the image"
    case "$PEERS" in "$NODE="*) ;; *) fail "pyone: peers are '$PEERS', not $NODE" ;; esac
    ok "B fetched python:3.12-slim from peer $NODE: $PEER peer bytes, 0 registry bytes"
    first_peer=$PEER

    # The second image shares most of its files with the first: B asks A only for the chunks it
    # does not hold yet, and counts the rest as cached.
    since=$(now_ms)
    apply "$(only_b pytwo $PY13_TREE $PY13_REF)"
    two_up() { [ "$(running_count pytwo)" -eq 1 ]; }
    until_ok 240 "pytwo to run on $NODE_B" two_up
    await_pull "$PY13_TREE" "$since"
    echo "pull record of pytwo: registry=$REG cached=$CACHED peer=$PEER peers=$PEERS"
    [ "$REG" -eq 0 ] || fail "pytwo: $REG registry bytes, but A has the image"
    [ "$PEER" -gt 0 ] || fail "pytwo: no bytes came from a peer"
    [ "$CACHED" -gt 0 ] || fail "pytwo: nothing was already held; the images do not overlap"
    ok "B fetched python:3.13-slim: $PEER peer bytes, $CACHED chunk bytes already held (only the rest moved)"
    curl -sf -X DELETE "$API/v1/services/pyone" >/dev/null || fail "delete pyone"
    curl -sf -X DELETE "$API/v1/services/pytwo" >/dev/null || fail "delete pytwo"
    ON=
}

stage_peers_fallback() {
    ON=$NODE_B
    # An image no peer has: the fetch fails, says why in fetch.log, and the supervisor's own pull
    # gets it from the registry.
    since=$(now_ms)
    apply "$(only_b mcached $MEMCACHED_TREE $MEMCACHED_REF)"
    mc_up() { [ "$(running_count mcached)" -eq 1 ]; }
    until_ok 240 "mcached to run on $NODE_B" mc_up
    await_pull "$MEMCACHED_TREE" "$since"
    echo "pull record of mcached: registry=$REG cached=$CACHED peer=$PEER peers=$PEERS"
    [ "$REG" -gt 0 ] || fail "mcached: no registry bytes"
    [ "$PEER" -eq 0 ] || fail "mcached: $PEER peer bytes, but no peer has the image"
    log=$(fetch_log_of mcached)
    [ -n "$log" ] && [ -s "$log" ] || fail "mcached: fetch.log is missing or empty ($log)"
    ok "an image no peer has: pulled from the registry ($REG bytes); fetch.log says: $(head -c 200 "$log" | tr '\n' ' ')"

    # The deadline: with the fault the fetch of alpine, which A holds, is killed at once, so the
    # tree must come from the registry. Without the kill the peer would have supplied it.
    echo 50 >"$B_DIR/agent/faults/fetch-deadline-ms" 2>/dev/null ||
        { mkdir -p "$B_DIR/agent/faults" && echo 50 >"$B_DIR/agent/faults/fetch-deadline-ms"; }
    since=$(now_ms)
    apply "$(only_b alp $ALPINE_TREE $ALPINE_REF)"
    alp_up() { [ "$(running_count alp)" -eq 1 ]; }
    until_ok 240 "alp to run on $NODE_B" alp_up
    rm -f "$B_DIR/agent/faults/fetch-deadline-ms"
    await_pull "$ALPINE_TREE" "$since"
    echo "pull record of alp: registry=$REG cached=$CACHED peer=$PEER peers=$PEERS"
    [ "$REG" -gt 0 ] || fail "alp: no registry bytes after the fetch was killed"
    [ "$PEER" -eq 0 ] || fail "alp: $PEER peer bytes; the fetch outlived its 50 ms deadline"
    pgrep -f 'zcube-agent fetch' >/dev/null && fail "a fetch is still running"
    ok "a fetch past its deadline (50 ms) is killed: alpine came from the registry ($REG bytes), not from $NODE"
    curl -sf -X DELETE "$API/v1/services/mcached" >/dev/null || fail "delete mcached"
    curl -sf -X DELETE "$API/v1/services/alp" >/dev/null || fail "delete alp"
    ON=
}

main() {
    stage=$1
    mkdir -p "$LOG"
    "stage_$stage" || fail "stage $stage"
}

main "$@"
