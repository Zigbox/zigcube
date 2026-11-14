#!/bin/sh
# The guest half of `zig build demo-b3` and `zig build demo-b4` (src/demo_b3.zig,
# docs/demos/b3.md, docs/demos/b4.md). The host half boots one guest, copies the binaries and this
# script in, and calls it as root with one command at a time. The server runs on the host; this
# guest runs one `zcube-agent --runtime zigbox` as root (as demo-c2's, ops/demo-c2/guest.sh) and
# a stock TLS upstream on its loopback (Python's ssl, which is OpenSSL).
#
# Commands:  guest.sh setup-root | learn <reference> | images <tree> <reference>
#            guest.sh agent <node> <server host:port> | restart | node-addr
#            guest.sh put <file> <base64 chunk> | upstream <cluster> <job,job,...>
#            guest.sh upstream-log | listeners | relay-logs | logs
#            guest.sh key-candidates <marker> | stop-relay <marker>
#
# Every command prints `ok: ...` for what it did, or `FAIL: ...` and exits 1.

BIN=/home/cube/bin
STATE=${STATE:-/root/state} # overridable for ops/demo-b3/test-guest.sh
LOG=/root/log
ARGS=/root/agent.args
UPSTREAM_PORT=9443
TLS=/root/tls
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

# Appends a base64 chunk to $TLS/<file>.b64 (a guest command is at most 1024 bytes, so the host
# sends the certificates in pieces); `upstream` decodes them.
cmd_put() {
    [ $# -eq 2 ] || fail "usage: guest.sh put <file> <base64 chunk>"
    case "$1" in server.pem | server.key | cluster-ca.pem) ;; *) fail "put: unknown file $1" ;; esac
    mkdir -p "$TLS"
    printf '%s' "$2" >>"$TLS/$1.b64" || fail "append to $TLS/$1.b64"
    ok "$1: $(wc -c <"$TLS/$1.b64") base64 bytes"
}

# The relays' upstream, `botpike`, on this guest's loopback: a stock TLS 1.3 server (Python's ssl
# module, OpenSSL) with the certificate the host's upstream CA issued, which requires a client
# certificate, pins the cluster CA (`cluster-ca.pem`, the server's `ca-*.crt`) and admits only the
# SPIFFE IDs `spiffe://<cluster>/job/<job>` of the jobs named. Each connection is logged with the
# client certificate's URI and DER (hex), for the host to decode the identity extension. HTTP
# inside: `/hold` answers and then waits for the connection to end (logged with its time);
# `/candidates` serves /root/candidates.hex; anything else is logged and answered `upstream-ok`.
# A UDP echo on every address's port 9091 is what the jobs' UDP attempts aim at.
cmd_upstream() {
    [ $# -eq 2 ] || fail "usage: guest.sh upstream <cluster> <job,job,...>"
    for file in server.pem server.key cluster-ca.pem; do
        [ -f "$TLS/$file.b64" ] || fail "no $file: guest.sh put it first"
        base64 -d "$TLS/$file.b64" >"$TLS/$file" || fail "decode $file"
    done
    chmod 600 "$TLS/server.key"
    cat >/root/upstream.py <<'PY'
import http.server, os, socket, socketserver, ssl, sys, threading, time
cluster, jobs = sys.argv[1], sys.argv[2].split(",")
allowed = {"spiffe://%s/job/%s" % (cluster, job) for job in jobs}
LOG = "/root/upstream.log"
lock = threading.Lock()
def log(line):
    with lock, open(LOG, "a") as f:
        f.write("%.3f %s\n" % (time.time(), line))
def uri_of(conn):
    for kind, value in (conn.getpeercert() or {}).get("subjectAltName", ()):
        if kind == "URI":
            return value
    return "-"
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        uri = uri_of(self.connection)
        der = self.connection.getpeercert(binary_form=True) or b""
        log("GET %s uri=%s der=%s" % (self.path, uri, der.hex()))
        body = b"upstream-ok"
        if self.path.startswith("/candidates"):
            try:
                body = open("/root/candidates.hex", "rb").read()
            except OSError:
                body = b""
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        if self.path.startswith("/hold"):
            log("hold-open uri=%s" % uri)
            self.connection.settimeout(0.2)
            while True:
                try:
                    if not self.connection.recv(1):
                        break
                except socket.timeout:
                    continue
                except (OSError, ssl.SSLError):
                    break
            log("hold-closed uri=%s" % uri)
            self.close_connection = True
    def log_message(self, *args):
        pass
class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    def verify_request(self, request, address):
        uri = uri_of(request)
        if uri not in allowed:
            log("refused uri=%s" % uri)
            return False
        return True
    def handle_error(self, request, address):
        log("error %s" % (sys.exc_info()[1],))
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_3
context.verify_mode = ssl.CERT_REQUIRED
context.load_verify_locations("/root/tls/cluster-ca.pem")
context.load_cert_chain("/root/tls/server.pem", "/root/tls/server.key")
server = Server(("127.0.0.1", 9443), Handler, bind_and_activate=False)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.server_bind()
server.server_activate()
def echo():
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("0.0.0.0", 9091))
    while True:
        data, peer = udp.recvfrom(512)
        log("udp from %s:%d" % peer)
        udp.sendto(data, peer)
threading.Thread(target=echo, daemon=True).start()
log("listening")
server.serve_forever()
PY
    : >/root/upstream.log
    setsid python3 /root/upstream.py "$1" "$2" >/root/upstream.err 2>&1 </dev/null &
    tries=0
    until grep -q listening /root/upstream.log; do
        tries=$((tries + 1))
        [ $tries -le 50 ] || fail "the upstream did not start: $(tail -5 /root/upstream.err)"
        sleep 0.2
    done
    # A client without a certificate is refused: the upstream is a TLS server that pins.
    if curl -sk -m 3 "https://127.0.0.1:$UPSTREAM_PORT/probe" >/dev/null 2>&1; then
        fail "the upstream answered a client with no certificate"
    fi
    : >/root/upstream.log
    ok "the TLS upstream listens on 127.0.0.1:$UPSTREAM_PORT for $2 of $1; UDP echo on :9091"
}

# The root-only tools of demo-b4, in Python. `key-candidates <marker>`: the run's key, read from
# its supervisor's memory (as root, from outside), for the job to search for. The supervisor
# keeps the Ed25519 secret key as seed || public key, so every 32 bytes just before a copy of the
# public key (relay.pub's first field) are a candidate seed; they go to /root/candidates.hex,
# which the upstream serves. `stop-relay <marker>`: the planned fault "the relay stopped mid-run":
# a duplicate of the supervisor's listener (pidfd_getfd) is shut down, so its accept fails and
# the relay must kill the run. The job is found by its last argument, `<marker>`.
write_tools() {
    cat >/root/tools.py <<'PY'
import ctypes, os, re, socket, sys
STATE = os.environ.get("STATE", "/root/state")
def argv(pid):
    try:
        return open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")[:-1]
    except OSError:
        return []
def job_pid(marker):
    for pid in filter(str.isdigit, os.listdir("/proc")):
        words = argv(pid)
        if len(words) > 2 and words[-1] == marker.encode() and words[0].endswith(b"python"):
            return pid
    sys.exit("FAIL: no process of the job marked %s" % marker)
def listener_inode(pid):
    for line in open("/proc/%s/net/tcp" % pid).read().splitlines()[1:]:
        f = line.split()
        if f[1].endswith(":1F90") and f[3] == "0A":
            return f[9]
    sys.exit("FAIL: nothing listens on 8080 in the job's namespace")
def supervisor_of(inode):
    for pid in filter(str.isdigit, os.listdir("/proc")):
        words = argv(pid)
        if len(words) < 2 or words[1] != b"supervise-zigbox":
            continue
        for fd in os.listdir("/proc/%s/fd" % pid):
            try:
                if os.readlink("/proc/%s/fd/%s" % (pid, fd)) == "socket:[%s]" % inode:
                    return pid, int(fd), words[2].decode()
            except OSError:
                pass
    sys.exit("FAIL: no supervisor holds the listener socket:[%s]" % inode)
def candidates(marker):
    pid, fd, directory = supervisor_of(listener_inode(job_pid(marker)))
    public = bytes.fromhex(open(directory + "/relay.pub").read().split()[0])
    found = set()
    mem = open("/proc/%s/mem" % pid, "rb")
    for line in open("/proc/%s/maps" % pid):
        f = line.split()
        if "r" not in f[1] or (len(f) > 5 and f[5].startswith("[v")):
            continue
        start, end = (int(x, 16) for x in f[0].split("-"))
        try:
            mem.seek(start)
            data = mem.read(end - start)
        except OSError:
            continue
        at = data.find(public)
        while at >= 0:
            if at >= 32:
                found.add(data[at - 32 : at])
            at = data.find(public, at + 1)
    found.discard(bytes(32))
    found = [c for c in found if c != public]
    if not found:
        sys.exit("FAIL: the run's key is not in supervisor %s's memory" % pid)
    with open("/root/candidates.hex", "w") as out:
        out.write(" ".join(c.hex() for c in sorted(found)))
    print("ok: %d candidate(s) from supervisor %s, public key %s" % (len(found), pid, public.hex()))
def stop_relay(marker):
    pid, fd, directory = supervisor_of(listener_inode(job_pid(marker)))
    libc = ctypes.CDLL(None, use_errno=True)
    pidfd = libc.syscall(434, int(pid), 0)
    if pidfd < 0:
        sys.exit("FAIL: pidfd_open: errno %d" % ctypes.get_errno())
    copy = libc.syscall(438, pidfd, fd, 0)
    if copy < 0:
        sys.exit("FAIL: pidfd_getfd: errno %d" % ctypes.get_errno())
    socket.socket(fileno=copy).shutdown(socket.SHUT_RDWR)
    print("ok: shut down supervisor %s's listener (fd %d)" % (pid, fd))
{"key-candidates": candidates, "stop-relay": stop_relay}[sys.argv[1]](sys.argv[2])
PY
}

cmd_tool() {
    [ $# -eq 2 ] || fail "usage: guest.sh $1 <marker>"
    write_tools
    STATE=$STATE python3 /root/tools.py "$1" "$2"
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

# Every job's relay.log, under the layout `--runtime zigbox` uses (<state>/zigbox/<name>/; the
# fake runtime's `containers/` does not exist there). With none at all it fails, so a wrong path
# cannot read as "nothing logged".
cmd_relay_logs() {
    found=0
    for log in "$STATE"/zigbox/*/relay.log; do
        [ -f "$log" ] || continue
        found=$((found + 1))
        echo "---- $log ----"
        cat "$log"
    done
    [ "$found" -gt 0 ] || fail "no relay.log under $STATE/zigbox/: the jobs' relays left none"
    echo "ok: $found relay.log files"
}

cmd_logs() {
    echo "---- agent.log (last 40 lines) ----"
    tail -40 "$LOG/agent.log" 2>/dev/null
    (cmd_relay_logs) || true
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
        put) cmd_put "$@" ;;
        upstream) cmd_upstream "$@" ;;
        key-candidates | stop-relay) cmd_tool "$command" "$@" ;;
        upstream-log) cmd_upstream_log ;;
        node-addr) cmd_node_addr ;;
        listeners) cmd_listeners ;;
        relay-logs) cmd_relay_logs ;;
        logs) cmd_logs ;;
        *) fail "unknown command $command" ;;
    esac
}

main "$@"
