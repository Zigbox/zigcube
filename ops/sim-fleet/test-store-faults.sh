#!/bin/sh
# Checks run.sh's daily `zig build test-store-faults` (store_faults_day, sf_backend, sf_record)
# against a fake `zig` that prints what the real runner prints, and the real `sim_fleet ingest
# --kind store-faults --dry-run`:
# - it runs once per UTC day, SQLite then Postgres, and a clean day files nothing;
# - a failed history check (SQLite) and a failed failover run (Postgres) are each filed, under
#   the step of their run;
# - a run that died after its header, a build that failed before any run, and a run that timed
#   out are each one crash record, filed;
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
ln -s "$fleet" "$bin/sim_fleet"
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
esac
FAKE
chmod +x "$work/fakebin/zig"
PATH="$work/fakebin:$PATH"

# Runs the day's run with SQLite in mode $1 and Postgres in mode $2; \$out is everything it said.
day() {
    echo "$1" >"$work/mode-sqlite"
    echo "$2" >"$work/mode-postgres"
    rm -f "$STATE/state.txt.dry" "$STATE/store-faults-day" "$work/calls"
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
expect "zig build test-store-faults -Dbackend=sqlite -Dseed=21"

case_name="failover failure"
day pass failover
expect "step: failover-async"
expect "zig build test-store-faults -Dbackend=postgres -Dseed=31"

case_name="died after its header"
day pass died
expect "store-faults: crash: "
expect "(step: postgres)"

case_name="build failed"
day nobuild pass
expect "expected declaration (step: before-run)"

case_name="timeout"
SIM_FLEET_STORE_FAULTS_TIMEOUT=1
day pass hang
SIM_FLEET_STORE_FAULTS_TIMEOUT=60
expect "crash: timed out after N s (step: postgres)"

case_name="no Postgres programs"
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
