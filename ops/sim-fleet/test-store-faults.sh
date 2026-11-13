#!/bin/sh
# Checks run.sh's daily `zig build test-store-faults` (store_faults_day, sf_backend, sf_record)
# against a fake `zig` that prints what the real runner prints, and the real `sim_fleet ingest
# --kind store-faults --dry-run`:
# - it runs once per UTC day, SQLite then Postgres, and a clean day files nothing;
# - a failed history check (SQLite) and a failed failover run (Postgres) are each filed, under
#   the step of their run;
# - a run that died after its header, a build that failed before any run, and a run that timed
#   out are each one crash record, filed;
# - a failed conformance run (Postgres) is filed though every runner passed, with a replay of
#   that run alone; a step that failed after every run passed is a crash at `after-run`;
# - a kill by SIGKILL (exit 137, or a child the build saw killed) says it was for memory;
# - every replay names its seed and its part (-Dstore-faults-only);
# - a report the reporter could not send leaves the day undone and is sent again next round
#   without running again; one it refused (exit 1) is not retried;
# - a host without the Postgres 16 programs is counted as runs that could not start, never filed;
# - SIM_FLEET_STORE_FAULTS=0 runs nothing.
# Usage: test-store-faults.sh PATH-TO-sim_fleet. Exits 1 on a failure.
set -eu
fleet=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
SIM_FLEET_SOURCE_ONLY=1
export SIM_FLEET_SOURCE_ONLY
. "$here/run.sh"
STATE=$work/state
built=abc123
bin=$STATE/bin/$built/bin
round=$STATE/round
SIM_FLEET_HOME=$work/home
SIM_FLEET_DRY_RUN=1
SIM_FLEET_REPORT_TIMEOUT=60
SIM_FLEET_BUILD_TIMEOUT=60
SIM_FLEET_STORE_FAULTS=1
SIM_FLEET_STORE_FAULTS_TIMEOUT=60
SIM_FLEET_PG_BIN=$work/pgbin
SIM_FLEET_TRACKER=
token_file=
mkdir -p "$bin" "$round" "$STATE/crashes" "$SIM_FLEET_PG_BIN" "$work/fakebin"
# The reporter: the real one, unless $work/ingest-exit holds the exit code it is to fail with.
cat >"$bin/sim_fleet" <<WRAP
#!/bin/sh
if [ -s "$work/ingest-exit" ]; then cat >/dev/null; exit "\$(cat "$work/ingest-exit")"; fi
exec "$fleet" "\$@"
WRAP
chmod +x "$bin/sim_fleet"
printf '#!/bin/sh\nexit 0\n' >"$SIM_FLEET_PG_BIN/initdb"
chmod +x "$SIM_FLEET_PG_BIN/initdb"
git() { :; } # The checkout of the built commit: the host's, not this test's.
fail() { echo "FAIL ($case_name): $*" >&2; exit 1; }
expect() { case "$out" in *"$1"*) ;; *) fail "wanted '$1' in: $out" ;; esac; }
refuse() { case "$out" in *"$1"*) fail "unwanted '$1' in: $out" ;; esac; }

# A fake `zig`: `build pg-up|pg-down|pg-pair-down` succeed; `build test-store-faults
# -Dbackend=B` prints what $work/mode-B asks and logs its call.
cat >"$work/fakebin/zig" <<FAKE
#!/bin/sh
echo "\$*" >>"$work/calls"
case "\$2" in
pg-up | pg-down | pg-pair-down) exit 0 ;;
esac
backend=\${3#-Dbackend=}
case "\$(cat "$work/mode-\$backend")" in
pass)
    echo "store-faults: backend=\$backend seed=11 (replay: -Dseed=11)"
    echo "store-faults: calls=1000 acked=990 failed=3 unknown=7 (applied=2 absent=5)"
    echo "store-faults: PASS"
    if [ "\$backend" = postgres ]; then
        for mode in sync async; do
            echo "store-faults: backend=postgres seed=11 (replay: -Dseed=11)"
            echo "store-faults: failover run: \$mode standby"
            echo "store-faults: failover \$mode: PASS: fine"
        done
    fi
    ;;
history)
    echo "store-faults: backend=\$backend seed=21 (replay: -Dseed=21)"
    echo "store-faults: history: .{ .failed = .{ .kind = .lost_write, .revision = 9, .key = 0 } }"
    echo "store-faults: FAIL seed=21 (replay: -Dseed=21)"
    echo "error: the following command exited with error code 1:"
    exit 1
    ;;
failover)
    echo "store-faults: backend=postgres seed=31 (replay: -Dseed=31)"
    echo "store-faults: PASS"
    echo "store-faults: backend=postgres seed=31 (replay: -Dseed=31)"
    echo "store-faults: failover run: async standby"
    echo "store-faults: failover async: FAILED: the server did not halt after 31 s"
    echo "store-faults: FAIL seed=31 (replay: -Dseed=31)"
    exit 1
    ;;
died)
    echo "store-faults: backend=\$backend seed=41 (replay: -Dseed=41)"
    echo "error: the following command terminated unexpectedly:" >&2
    exit 1
    ;;
nobuild)
    echo "error: src/store_faults.zig:5:1: expected declaration" >&2
    exit 1
    ;;
hang)
    echo "store-faults: backend=\$backend seed=51 (replay: -Dseed=51)"
    exec sleep 30
    ;;
conformance)
    # Real output of a failed conformance run (the build runner's summary, trimmed), after a
    # 10c run and failover runs that passed.
    echo "store-faults: backend=postgres seed=61 (replay: -Dseed=61)"
    echo "store-faults: PASS"
    echo "store-faults: backend=postgres seed=62 (replay: -Dseed=62)"
    echo "store-faults: failover run: sync standby"
    echo "store-faults: failover sync: PASS: no acknowledged write lost"
    echo "test-store-faults"
    echo "+- run test 137 pass, 57 fail (194 total)"
    echo "error: 'store_conformance.test.txn: the result's hash is the chain hash of its revision' failed:"
    echo "       store conformance: backend=postgres seed=63 (replay: -Dseed=63)"
    echo "       /home/user/zigcube/src/pq.zig:482:5: 0x12f4988 in fill (store_conformance.zig)"
    echo "error: 'store_conformance.test.txn: a failed compare writes nothing' failed:"
    echo "       store conformance: backend=postgres seed=63 (replay: -Dseed=63)"
    exit 1
    ;;
passexit)
    echo "store-faults: backend=\$backend seed=71 (replay: -Dseed=71)"
    echo "store-faults: PASS"
    echo "error: unable to write the step's output: NoSpaceLeft"
    exit 1
    ;;
oom)
    echo "store-faults: backend=\$backend seed=81 (replay: -Dseed=81)"
    exit 137
    ;;
childoom)
    echo "store-faults: backend=\$backend seed=82 (replay: -Dseed=82)"
    echo "test-store-faults"
    echo "+- run exe store_faults failure"
    echo "error: process terminated with signal KILL (expected exited with code 0)"
    exit 1
    ;;
esac
FAKE
chmod +x "$work/fakebin/zig"
PATH="$work/fakebin:$PATH"

# Runs the day's run with SQLite in mode $1 and Postgres in mode $2; \$out is everything it said.
day() {
    echo "$1" >"$work/mode-sqlite"
    echo "$2" >"$work/mode-postgres"
    rm -f "$STATE/state.txt.dry" "$STATE/store-faults-day" "$work/calls" "$work/ingest-exit"
    rm -rf "$STATE/store-faults-pending"
    out=$(store_faults_day 2>&1)
}

case_name="clean day"
day pass pass
expect "store-faults: running at abc123"
refuse "would file"
grep -q "test-store-faults -Dbackend=sqlite" "$work/calls" || fail "no sqlite run"
grep -q "test-store-faults -Dbackend=postgres" "$work/calls" || fail "no postgres run"
[ "$(cat "$STATE/store-faults-day")" = "$(date -u +%Y-%m-%d)" ] || fail "the day was not kept"
expect "0 failed"
case_name="once a day"
rm -f "$work/calls"
out=$(store_faults_day 2>&1)
[ ! -e "$work/calls" ] || fail "ran twice in a day"
echo 2000-01-01 >"$STATE/store-faults-day"
out=$(store_faults_day 2>&1)
[ -e "$work/calls" ] || fail "did not run on the next day"

case_name="history failure"
day history pass
expect "store-faults: history: lost_write (step: sqlite)"
expect "zig build test-store-faults -Dbackend=sqlite -Dseed=21 -Dstore-faults-only=faults"

case_name="failover failure"
day pass failover
expect "step: failover-async"
expect "zig build test-store-faults -Dbackend=postgres -Dseed=31 -Dstore-faults-only=async"

case_name="died after its header"
day pass died
expect "store-faults: crash: "
expect "(step: postgres)"
expect "zig build pg-up && zig build test-store-faults -Dbackend=postgres -Dseed=41"

case_name="build failed"
day nobuild pass
expect "expected declaration (step: before-run)"

case_name="timeout"
SIM_FLEET_STORE_FAULTS_TIMEOUT=1
day pass hang
SIM_FLEET_STORE_FAULTS_TIMEOUT=60
expect "crash: timed out after N s (step: postgres)"

case_name="conformance failed, runners passed"
day pass conformance
expect "would file"
expect "conformance: txn: the result's hash is the chain hash of its revision"
expect "(step: conformance)"
expect "-Dbackend=postgres -Dseed=63 -Dstore-faults-only=conformance"
# The record ends its line, or a record that follows it would be read as part of its replay.
[ -z "$(tail -c1 "$round/all-store-faults")" ] || fail "the record does not end in a newline"
refuse "0 failed"

case_name="failed after every run passed"
day passexit pass
expect "crash: unable to write the step's output: NoSpaceLeft (step: after-run)"

case_name="killed for memory"
day oom pass
expect "crash: killed by SIGKILL, for memory (the kernel's out-of-memory killer) (step: sqlite)"
expect "-Dbackend=sqlite -Dseed=81 -Dstore-faults-only=faults"
day pass childoom
expect "crash: killed by SIGKILL, for memory (the kernel's out-of-memory killer) (step: postgres)"

case_name="report not sent"
# Takes the reporter down (exit $1) for one day's run of a SQLite history failure.
down_day() {
    day pass pass
    rm -f "$STATE/store-faults-day" "$work/calls"
    echo history >"$work/mode-sqlite"
    echo "$1" >"$work/ingest-exit"
    out=$(store_faults_day 2>&1)
}
down_day 2
[ ! -e "$STATE/store-faults-day" ] || fail "the day was marked done before its report went out"
[ -s "$STATE/store-faults-pending/output" ] || fail "the day's output was not kept"
expect "is sent again next round"
rm -f "$work/ingest-exit" "$work/calls"
out=$(store_faults_day 2>&1)
[ ! -e "$work/calls" ] || fail "ran again instead of sending the kept report"
expect "store-faults: history: lost_write (step: sqlite)"
[ "$(cat "$STATE/store-faults-day")" = "$(date -u +%Y-%m-%d)" ] || fail "the day was not kept"
[ ! -e "$STATE/store-faults-pending" ] || fail "the sent report was kept"
out=$(store_faults_day 2>&1)
[ ! -e "$work/calls" ] || fail "ran twice in a day"
case_name="report timed out"
down_day 124
[ ! -e "$STATE/store-faults-day" ] || fail "the day was marked done before its report went out"
case_name="report refused"
down_day 1
[ "$(cat "$STATE/store-faults-day")" = "$(date -u +%Y-%m-%d)" ] || fail "a refusal was retried"
[ ! -e "$STATE/store-faults-pending" ] || fail "a refused report was kept"
rm -f "$work/ingest-exit"

mv "$SIM_FLEET_PG_BIN/initdb" "$work/initdb"
day pass pass
mv "$work/initdb" "$SIM_FLEET_PG_BIN/initdb"
refuse "would file"
expect "1 could not start"
expect "no Postgres 16 programs in"

case_name="turned off"
SIM_FLEET_STORE_FAULTS=0
day pass pass
[ ! -e "$work/calls" ] || fail "ran while turned off"
echo "test-store-faults.sh: PASS"
