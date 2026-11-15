#!/bin/sh
# Checks run.sh's soak branches and heartbeat (follow_refs, pick_ref, prune_bin, heartbeat)
# against a local bare repository as the remote, a fake build and fake producers:
# - the branches with a build take turns, one round each, SIM_FLEET_BRANCH first;
# - a branch deleted from the remote is dropped with one log line, its binaries pruned, and is
#   back in the rotation when it comes back; a branch whose build fails is not run;
# - every ingest gets `--ref` and `--round-started`;
# - `sim_fleet heartbeat` gets `--clean` only after a round whose every ingest succeeded, and the
#   heartbeat URL is never on a command line;
# - the real `sim_fleet heartbeat` sends one GET to a local fake server after a clean round and
#   none otherwise, and logs "heartbeat sent" without the URL.
# Usage: test-soak.sh PATH-TO-sim_fleet. Exits 1 on a failure.
set -eu
fleet=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
server_pid=""
trap 'if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
SIM_FLEET_SOURCE_ONLY=1
export SIM_FLEET_SOURCE_ONLY
. "$here/run.sh"
fail() { echo "FAIL ($case_name): $*" >&2; exit 1; }
expect() { case "$out" in *"$1"*) ;; *) fail "wanted '$1' in: $out" ;; esac; }
refuse() { case "$out" in *"$1"*) fail "unwanted '$1' in: $out" ;; esac; }

# The remote: three branches, each at a commit of its own.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git init --quiet --bare -b main "$work/remote.git"
git init --quiet "$work/src"
commit_on() { # branch
    (cd "$work/src" && git checkout --quiet -B "$1" && echo "$1 $(date +%s%N)" >f &&
        git add f && git commit --quiet -m "$1" &&
        git -c push.negotiate=false push --quiet --force origin "$1" 2>/dev/null)
}
(cd "$work/src" && git remote add origin "$work/remote.git")
commit_on main
commit_on rel/1.0
commit_on rel/2.0
git clone --quiet "$work/remote.git" "$work/checkout"
cd "$work/checkout"
tip() { git --git-dir="$work/remote.git" rev-parse "refs/heads/$1"; }

STATE=$work/state
mkdir -p "$STATE/bin" "$STATE/crashes"
SIM_FLEET_BRANCH=main
REFS="main rel/1.0 rel/2.0 rel/never"
SIM_FLEET_GIT_TIMEOUT=60
SIM_FLEET_REPORT_TIMEOUT=60
SIM_FLEET_BATCH_TIMEOUT=60
SIM_FLEET_CANARY_ONE_IN=0
SIM_FLEET_TRACKER=
SIM_FLEET_OPS=auto
SIM_FLEET_PROFILE=auto
SIM_FLEET_GH_REPO=example/repo
SIM_FLEET_BATCH_CLUSTER=3
SIM_FLEET_WORKERS_CLUSTER=1
KINDS=sim-cluster

# The build: a commit listed in $work/broken fails; any other gets a fake sim_swarm, a fake
# sim_cluster that prints a passing batch and a fake sim_fleet that records its arguments and
# exits with the code in $work/ingest-code.
: >"$work/broken"
build_commit() {
    if grep -qx "$1" "$work/broken"; then return 1; fi
    b=$STATE/bin/$1/bin
    mkdir -p "$b"
    printf '#!/bin/sh\nexit 0\n' >"$b/sim_swarm"
    cat >"$b/sim_cluster" <<'EOF'
#!/bin/sh
range=$2
printf 'sim-cluster: seeds %s, drawn operations: 0 of 3 failed\n' "$range"
EOF
    cat >"$b/sim_fleet" <<EOF
#!/bin/sh
echo "\$*" >>"$work/fleet-args"
if [ "\$1" = ingest ]; then cat >/dev/null; exit \$(cat "$work/ingest-code"); fi
exit 0
EOF
    chmod +x "$b/sim_swarm" "$b/sim_cluster" "$b/sim_fleet"
}

# Rounds of pick_ref; prints the branch each picked.
picks() { # rounds
    k=0
    names=""
    while [ "$k" -lt "$1" ]; do
        pick_ref
        names="$names $ref"
        k=$((k + 1))
    done
    echo "$names"
}

case_name="round robin"
out=$(follow_refs 2>&1)
expect "built $(tip main) (main)"
expect "built $(tip rel/2.0) (rel/2.0)"
expect "branch rel/never is gone from the remote"
out=$(follow_refs 2>&1)
refuse "building"
refuse "rel/never"
out=$(picks 7)
[ "$out" = " main rel/1.0 rel/2.0 main rel/1.0 rel/2.0 main" ] || fail "picked$out"

case_name="a moved branch is rebuilt, a broken build is not run"
commit_on rel/2.0
tip rel/2.0 >>"$work/broken"
out=$(follow_refs 2>&1)
expect "build of $(tip rel/2.0) (rel/2.0) FAILED"
out=$(follow_refs 2>&1)
refuse "FAILED"
out=$(picks 3)
[ "$out" = " rel/1.0 rel/2.0 main" ] || fail "picked$out (the old rel/2.0 build stays)"

case_name="a dropped branch"
old=$(tip rel/1.0)
git --git-dir="$work/remote.git" update-ref -d refs/heads/rel/1.0
out=$(follow_refs 2>&1)
expect "branch rel/1.0 is gone from the remote; dropped until it comes back"
[ ! -d "$STATE/bin/$old" ] || fail "the binaries of $old were kept"
out=$(follow_refs 2>&1)
refuse "rel/1.0"
echo 0 >"$STATE/ref-next"
out=$(picks 4)
[ "$out" = " main rel/2.0 main rel/2.0" ] || fail "picked$out"
commit_on rel/1.0
out=$(follow_refs 2>&1)
expect "branch rel/1.0 is back"
expect "built $(tip rel/1.0) (rel/1.0)"

case_name="ingest gets the branch; heartbeat --clean only after a clean round"
SIM_FLEET_DRY_RUN=
token_file=$work/token
echo fake-token >"$token_file"
heartbeat_file=$work/heartbeat-url
echo "http://127.0.0.1:9/secret-heartbeat-path" >"$heartbeat_file"
echo 0 >"$work/ingest-code"
echo 0 >"$STATE/ref-next"
pick_ref
: >"$work/fleet-args"
out=$(run_round 2>&1)
out=$(cat "$work/fleet-args")
expect "ingest --kind sim-cluster --commit $(tip main) --state $STATE/state.txt --ref main"
expect "--round-started "
expect "heartbeat --repo example/repo --token-file $token_file --state $STATE/state.txt"
expect "--url-file $heartbeat_file --clean"
refuse "secret-heartbeat-path"
refuse "fake-token"
echo 2 >"$work/ingest-code"
pick_ref
: >"$work/fleet-args"
out=$(run_round 2>&1)
expect "sim_fleet ingest exited 2"
out=$(cat "$work/fleet-args")
expect "--ref rel/1.0"
expect "heartbeat --repo"
refuse "--clean"

case_name="no heartbeat file, dry run: no heartbeat call"
SIM_FLEET_DRY_RUN=1
heartbeat_file=""
echo 0 >"$work/ingest-code"
pick_ref
: >"$work/fleet-args"
out=$(run_round 2>&1)
out=$(cat "$work/fleet-args")
refuse "heartbeat"

# The real reporter against a local fake server: one GET per clean round, none otherwise.
case_name="sim_fleet heartbeat against a local server"
cat >"$work/server.py" <<'EOF'
import http.server, sys
log = open(sys.argv[1], "a", buffering=1)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        log.write(self.command + " " + self.path + "\n")
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()
EOF
: >"$work/requests"
python3 -I "$work/server.py" "$work/requests" "$work/port" &
server_pid=$!
k=0
while [ ! -s "$work/port" ]; do
    k=$((k + 1))
    [ "$k" -lt 100 ] || fail "the fake server did not start"
    sleep 0.1
done
url_file=$work/real-url
echo "http://127.0.0.1:$(cat "$work/port")/ping/secret-part" >"$url_file"
out=$("$fleet" heartbeat --url-file "$url_file" 2>&1)
[ ! -s "$work/requests" ] || fail "a heartbeat without --clean was sent"
out=$("$fleet" heartbeat --url-file "$url_file" --clean 2>&1)
expect "heartbeat sent"
refuse "secret-part"
[ "$(cat "$work/requests")" = "GET /ping/secret-part" ] || fail "requests: $(cat "$work/requests")"
out=$("$fleet" heartbeat --url-file "$work/absent" --clean 2>&1)
[ "$(wc -l <"$work/requests")" -eq 1 ] || fail "a heartbeat was sent without a URL file"
echo "test-soak: ok"
