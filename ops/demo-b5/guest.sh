#!/bin/sh
# The guest half of `zig build demo-b5` (src/demo_b5.zig, docs/demos/b5.md). The host half boots
# one guest, copies the binaries and this script in, and calls it as root with one command at a
# time. The server runs on the host; this guest runs one `zcube-agent --runtime zigbox` as root
# (as demo-b3's, ops/demo-b3/guest.sh) with `--trust-policy`, and is also where the jobs are signed:
# a signer's own Zigbox store and key directory (`$SIGNER`), apart from the node's store, holds the
# pulled images and two keys, `release` (trusted) and `stranger` (trusted by no policy).
#
# Commands:  guest.sh setup-root | pull <reference> | key-new <name> | sign <key> <tree>
#            guest.sh export <tree> | policy <public key> | kept <container> <tree>
#            guest.sh images <tree> <reference> ...
#            guest.sh agent <node> <server host:port> | containers | logs
#
# Every command prints `ok: ...` for what it did, or `FAIL: ...` and exits 1.

BIN=${BIN:-/home/cube/bin}
STATE=${STATE:-/root/state}
LOG=${LOG:-/root/log}
ARGS=/root/agent.args
IMAGES=/root/images.zon
POLICY=${POLICY:-/root/trust.zon}
SIGNER=${SIGNER:-/root/signer}
NODE_POLICY=${NODE_POLICY:-${XDG_CONFIG_HOME:-/root/.config}/zbx/policy.zon}
ROOT_RANGE=200000:65536

export HOME=/root
export XDG_RUNTIME_DIR=/run/user/0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus

fail() {
    echo "FAIL: $*"
    exit 1
}

ok() { echo "ok: $*"; }

agent_pid() { pgrep -f "^$BIN/zcube-agent --runtime"; }

# zbx as the signer: its own store, cache, state and key directory, none of them the node's.
signer() {
    mkdir -p "$SIGNER/data" "$SIGNER/cache" "$SIGNER/state" "$SIGNER/config"
    XDG_DATA_HOME="$SIGNER/data" XDG_CACHE_HOME="$SIGNER/cache" \
        XDG_STATE_HOME="$SIGNER/state" XDG_CONFIG_HOME="$SIGNER/config" "$BIN/zbx" "$@"
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

# Pulls an image into the signer's store (`zbx sign` needs the whole tree there) and prints its
# tree digest, which is also the one the node's agent gets for it on this guest.
cmd_pull() {
    [ $# -eq 1 ] || fail "usage: guest.sh pull <reference>"
    out=$(signer pull --output json "$1" 2>"$SIGNER.err")
    status=$?
    [ $status -eq 0 ] || fail "zbx pull $1 exited $status: $(tail -5 "$SIGNER.err")"
    tree=$(printf '%s' "$out" | sed -n 's/.*"tree":"\(b3:[0-9a-f]\{64\}\)".*/\1/p')
    [ -n "$tree" ] || fail "zbx pull $1 printed no tree"
    echo "tree $tree"
}

# A signing key with no passphrase (a demo key); prints its public text, `zbx-ed25519:<hex>`.
cmd_key_new() {
    [ $# -eq 1 ] || fail "usage: guest.sh key-new <name>"
    signer key new "$1" --no-passphrase >"$SIGNER.out" 2>&1 ||
        fail "zbx key new $1: $(tail -5 "$SIGNER.out")"
    public=$(head -1 "$SIGNER/config/zbx/keys/$1.pub")
    case "$public" in
        zbx-ed25519:*) echo "public $public" ;;
        *) fail "no public key in $SIGNER/config/zbx/keys/$1.pub" ;;
    esac
}

cmd_sign() {
    [ $# -eq 2 ] || fail "usage: guest.sh sign <key> <tree>"
    signer sign "$2" --key "$1" >"$SIGNER.out" 2>&1 ||
        fail "zbx sign $2 --key $1: $(tail -5 "$SIGNER.out")"
    ok "zbx sign $2 --key $1"
}

# Every signature the signer's store holds for the tree, one DSSE envelope per line, each line
# prefixed `line ` so the host can tell them from anything else printed.
cmd_export() {
    [ $# -eq 1 ] || fail "usage: guest.sh export <tree>"
    signer trust export "$1" >"$SIGNER.lines" 2>"$SIGNER.err" ||
        fail "zbx trust export $1: $(tail -5 "$SIGNER.err")"
    count=0
    # `|| [ -n "$line" ]`: a last line without a newline is still a line.
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        count=$((count + 1))
        echo "line $line"
    done <"$SIGNER.lines"
    [ "$count" -gt 0 ] || fail "zbx trust export $1 printed no line"
    ok "$count line(s) for $1"
}

# The node's own trust policy: the one key, a signature required. Root's file, mode 0644. The same
# policy is also the node's Zigbox policy (`$NODE_POLICY`, where the agent's zbx looks: the user's
# `zbx/policy.zon` under the agent's environment), so the agent puts a job's signatures into the
# node's Zigbox store before the start (`import_signatures`) and `kept` can see them there. The
# signer's zbx has a config directory of its own and does not read it.
cmd_policy() {
    [ $# -eq 1 ] || fail "usage: guest.sh policy <public key>"
    key='.{ .name = "release", .public = "'"$1"'" }'
    printf '.{ .version = 1, .keys = .{ %s }, .require_signature = true }\n' "$key" >"$POLICY" ||
        fail "write $POLICY"
    chmod 0644 "$POLICY" || fail "chmod 0644 $POLICY"
    mkdir -p "$(dirname "$NODE_POLICY")" || fail "mkdir $(dirname "$NODE_POLICY")"
    cp "$POLICY" "$NODE_POLICY" || fail "copy $POLICY to $NODE_POLICY"
    chmod 0644 "$NODE_POLICY" || fail "chmod 0644 $NODE_POLICY"
    ok "$POLICY and $NODE_POLICY trust $1 and require a signature"
}

# Whether the agent kept a job's signatures in the node's Zigbox store: no "were not kept" line
# in its log (ZBX-E0909, the start goes on without them), and the node's own `zbx trust export`
# of the tree, as the agent's environment finds the store, prints at least one line.
cmd_kept() {
    [ $# -eq 2 ] || fail "usage: guest.sh kept <container> <tree>"
    if grep "container $1: its signatures were not kept" "$LOG/agent.log" >"$LOG/kept.err"; then
        fail "the agent did not keep $1's signatures: $(tail -1 "$LOG/kept.err")"
    fi
    "$BIN/zbx" trust export "$2" >"$LOG/kept.out" 2>"$LOG/kept.err" ||
        fail "the node's zbx trust export $2: $(tail -5 "$LOG/kept.err")"
    count=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] && count=$((count + 1))
    done <"$LOG/kept.out"
    [ "$count" -gt 0 ] || fail "the node's Zigbox store holds no signature for $2"
    ok "the node's Zigbox store holds $count line(s) for $2; no 'not kept' line for $1"
}

# Tells the agent where to pull each tree from (a job names an image by its tree digest only).
cmd_images() {
    [ $# -ge 2 ] || fail "usage: guest.sh images <tree> <reference> ..."
    entries=""
    while [ $# -ge 2 ]; do
        entries="$entries .{ .digest = \"$1\", .reference = \"$2\" },"
        shift 2
    done
    printf '.{ .images = .{%s } }\n' "$entries" >"$IMAGES" || fail "write $IMAGES"
    ok "$IMAGES:$entries"
}

cmd_agent() {
    [ $# -eq 2 ] || fail "usage: guest.sh agent <node> <server>"
    [ -f "$IMAGES" ] || fail "no $IMAGES: run guest.sh images first"
    [ -f "$POLICY" ] || fail "no $POLICY: run guest.sh policy first"
    mkdir -p "$STATE" "$LOG"
    echo "--runtime zigbox --node $1 --server $2 --state-dir $STATE --cpu-millis 2000" \
        "--memory-bytes 1073741824 --images $IMAGES --trust-policy $POLICY --verbose" >"$ARGS"
    # The arguments hold no space; word splitting is wanted.
    # shellcheck disable=SC2046
    setsid "$BIN/zcube-agent" $(cat "$ARGS") >>"$LOG/agent.log" 2>&1 </dev/null &
    sleep 1
    agent_pid >/dev/null || fail "the agent exited at once: $(tail -20 "$LOG/agent.log")"
    ok "zcube-agent --runtime zigbox --node $1 --trust-policy $POLICY (pid $(agent_pid))"
}

# The containers the Zigbox runtime made on this node, by name (its layout: <state>/zigbox/<name>/),
# one `container <name>` line each. A refused run must have none. No zigbox/ at all (the runtime
# makes it when the agent starts) fails, so the demo's "no container" cannot hold for a wrong path.
cmd_containers() {
    [ -d "$STATE/zigbox" ] || fail "no $STATE/zigbox: not the layout of --runtime zigbox"
    for dir in "$STATE"/zigbox/*/; do
        [ -d "$dir" ] || continue
        echo "container $(basename "$dir")"
    done
    ok "listed $STATE/zigbox/"
}

cmd_logs() {
    echo "---- agent.log (last 40 lines) ----"
    tail -40 "$LOG/agent.log" 2>/dev/null
    echo "---- signer ----"
    cat "$SIGNER.out" "$SIGNER.err" 2>/dev/null
    echo "---- containers ----"
    ls -la "$STATE/zigbox" 2>/dev/null
    echo "---- processes ----"
    ps -eo pid,etime,args | grep -E 'zcube|zbx' | grep -v grep
}

main() {
    command=$1
    shift
    case "$command" in
        setup-root) cmd_setup_root ;;
        pull) cmd_pull "$@" ;;
        key-new) cmd_key_new "$@" ;;
        sign) cmd_sign "$@" ;;
        export) cmd_export "$@" ;;
        policy) cmd_policy "$@" ;;
        kept) cmd_kept "$@" ;;
        images) cmd_images "$@" ;;
        agent) cmd_agent "$@" ;;
        containers) cmd_containers ;;
        logs) cmd_logs ;;
        *) fail "unknown command $command" ;;
    esac
}

main "$@"
