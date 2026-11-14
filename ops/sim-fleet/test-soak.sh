#!/bin/sh
# Checks soak.sh end to end against a fake `sim_cluster` and the real `sim_fleet`, dry run:
# - a soak that held is counted and files nothing; the seed, minutes and epoch reach the runner;
# - a soak that failed is filed under `sim-soak` with its replay and its trace;
# - a soak that died is recorded as CRASHED with a replay one epoch past its last epoch line;
# - the binaries are copies, so run.sh may prune its own while a soak runs;
# - settings that are not numbers are refused.
# Usage: test-soak.sh PATH-TO-sim_fleet. Exits 1 on a failure.
set -eu
fleet=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
state=$work/state
bin=$state/bin/abc123/bin
mkdir -p "$bin"
echo abc123 >"$state/built"
cp "$fleet" "$bin/sim_fleet"
fail() { echo "FAIL ($case_name): $*" >&2; exit 1; }
expect() { case "$out" in *"$1"*) ;; *) fail "wanted '$1' in: $out" ;; esac; }
refuse() { case "$out" in *"$1"*) fail "unwanted '$1' in: $out" ;; esac; }

# The fake runner does what $work/mode says: `held`, `failed` or `crashed`.
cat >"$bin/sim_cluster" <<EOF
#!/bin/sh
echo "\$*" >>"$work/args"
echo "soak: epoch 1 operations=100 wall_ms=1 virtual_ms=1 revision=1"
echo "soak: epoch 2 operations=200 wall_ms=2 virtual_ms=2 revision=2"
case \$(cat "$work/mode") in
held)
    echo "soak: held for 200 operations, 2 epochs, peak 1000 bytes"
    echo "sim-cluster --soak: seeds \$1..\$1, 200 operations: 0 of 1 failed"
    ;;
failed)
    echo "seed \$1: FAILED: soak: memory grew faster than the history it holds"
    echo "  step: soak"
    echo "  profile: mixed"
    echo "  replay: zig-out/bin/sim_cluster \$1 soak 0 --soak-operations=200 --soak-epoch=100"
    echo "  soak: live bytes per item 81 against a baseline of 20"
    echo "sim-cluster --soak: seeds \$1..\$1, 200 operations: 1 of 1 failed"
    exit 1
    ;;
crashed)
    echo "thread 1 panic: integer overflow" >&2
    kill -9 \$\$
    ;;
esac
EOF
chmod +x "$bin/sim_cluster"

soak() {
    echo "$1" >"$work/mode"
    out=$(SIM_FLEET_STATE_DIR=$state SIM_FLEET_DRY_RUN=1 SIM_SOAK_ROUNDS=1 SIM_SOAK_SEED=42 \
        SIM_SOAK_MINUTES=7 SIM_SOAK_EPOCH=100 sh "$here/soak.sh" 2>&1) || fail "exited $?: $out"
}

case_name="a soak that held"
soak held
expect "1 seeds, 0 failed"
refuse "would file issue"
grep -qx "42 soak --soak-minutes=7 --soak-epoch=100" "$work/args" || fail "args: $(cat "$work/args")"
[ -x "$state/soak/bin/sim_cluster" ] || fail "the runner was not copied"

case_name="the runner is a copy run.sh's prune cannot take"
copy=$state/soak/bin/sim_cluster
if [ -L "$copy" ] || [ "$copy" -ef "$bin/sim_cluster" ]; then fail "not a copy"; fi
cmp -s "$copy" "$bin/sim_cluster" || fail "the copy differs"

case_name="a soak that failed"
soak failed
expect "would file issue: sim-soak: soak: memory grew faster than the history it holds"
expect "zig-out/bin/sim_cluster 42 soak 0 --soak-operations=200 --soak-epoch=100"
expect "Trace: the last operations before the failure"
expect "soak: live bytes per item 81 against a baseline of 20"

case_name="a soak that died"
soak crashed
expect "sim_cluster exited 137 on seed 42; recording a crash"
expect "sim-soak"
expect "integer overflow"
expect "zig-out/bin/sim_cluster 42 soak --soak-operations=300 --soak-epoch=100"
[ -f "$state/soak/last-1.log" ] || fail "the round before was not kept"

case_name="a setting that is not a number"
code=0
out=$(SIM_FLEET_STATE_DIR=$state SIM_FLEET_DRY_RUN=1 SIM_SOAK_MINUTES=six \
    sh "$here/soak.sh" 2>&1) || code=$?
[ "$code" -eq 2 ] || fail "exited $code: $out"
expect "SIM_SOAK_MINUTES is 'six': it must be a number"
echo "test-soak: ok"
