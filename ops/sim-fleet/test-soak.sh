#!/bin/sh
# Checks soak.sh end to end against the real `sim_fleet`, dry run:
# - a real soak (`sim_cluster`, Debug) that held is counted, files nothing and prints its world
#   hash; the seed, minutes and epoch reach the runner;
# - a real soak of the soak tooth (`sim_soak_teeth`: 16 KiB never freed per operation) fails the
#   teardown check and is filed under `sim-soak` with its replay and its trace;
# - with a fake runner: stderr is noted in the verdict before the summary line; a run that died
#   is recorded as CRASHED with a replay one epoch past its last epoch line; a run killed by
#   signal 9 (exit 137) and a refused run (exit 2) are logged and not reported;
# - the binaries are copies, so run.sh may prune its own while a soak runs;
# - settings that are not numbers, a second soak and a missing token are refused.
# Usage: test-soak.sh PATH-TO-sim_fleet PATH-TO-sim_cluster PATH-TO-sim_soak_teeth.
# Exits 1 on a failure.
set -eu
absolute() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
fleet=$(absolute "$1")
real_cluster=$(absolute "$2")
real_teeth=$(absolute "$3")
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

soak() {
    echo "$1" >"$work/mode"
    out=$(SIM_FLEET_STATE_DIR=$state SIM_FLEET_DRY_RUN=1 SIM_SOAK_ROUNDS=1 SIM_SOAK_SEED=42 \
        SIM_SOAK_MINUTES=7 SIM_SOAK_EPOCH=100 sh "$here/soak.sh" 2>&1) || fail "exited $?: $out"
}

# A real runner, ended by 300 operations: soak.sh passes --soak-minutes, which a Debug build
# would spend whole, so the wrapper records the arguments and runs the operations instead (the
# runner refuses both ends at once).
real() {
    {
        echo '#!/bin/sh'
        echo "echo \"\$*\" >>\"$work/args\""
        echo "exec \"$1\" \"\$1\" soak --soak-operations=300 --soak-epoch=100"
    } >"$bin/sim_cluster"
    chmod +x "$bin/sim_cluster"
}

case_name="a real soak that held"
real "$real_cluster"
soak real
expect "1 seeds, 0 failed"
refuse "would file issue"
grep -q "^soak: held for 300 operations, 3 epochs" "$state/soak/verdict" ||
    fail "not held: $(cat "$state/soak/verdict")"
grep -q "^world hash: " "$state/soak/verdict" || fail "no world hash: $(cat "$state/soak/verdict")"
grep -qx "42 soak --soak-minutes=7 --soak-epoch=100" "$work/args" || fail "args: $(cat "$work/args")"
[ -x "$state/soak/bin/sim_cluster" ] || fail "the runner was not copied"

case_name="the runner is a copy run.sh's prune cannot take"
copy=$state/soak/bin/sim_cluster
if [ -L "$copy" ] || [ "$copy" -ef "$bin/sim_cluster" ]; then fail "not a copy"; fi
cmp -s "$copy" "$bin/sim_cluster" || fail "the copy differs"

case_name="a real soak of the leaking tooth"
real "$real_teeth"
soak real
expect "would file issue: sim-soak: soak: memory still held after the world was torn down"
expect "zig-out/bin/sim_cluster 42 soak"
expect "Trace: the last operations before the failure"
expect "bytes after a run of 300 operations"
expect "soak: stderr not empty: error(SafeAllocator): leaked"

# The fake runner does what $work/mode says: `stderr`, `crashed`, `killed` or `refused`.
cat >"$bin/sim_cluster" <<EOF
#!/bin/sh
echo "soak: epoch 1 operations=100 wall_ms=1 virtual_ms=1 revision=1"
echo "soak: epoch 2 operations=200 wall_ms=2 virtual_ms=2 revision=2"
case \$(cat "$work/mode") in
stderr)
    echo 'warning: \`\`\` something odd' >&2
    echo "second line" >&2
    echo "soak: held for 200 operations, 2 epochs, peak 1000 bytes"
    echo "world hash: 0x1"
    echo "sim-cluster --soak: seeds \$1..\$1, 200 operations: 0 of 1 failed"
    ;;
crashed)
    echo "thread 1 panic: integer overflow" >&2
    exit 134
    ;;
killed)
    kill -9 \$\$
    ;;
refused)
    echo "sim_cluster: --soak-epoch: not a number" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$bin/sim_cluster"

case_name="a soak that wrote to stderr"
soak stderr
expect "1 seeds, 0 failed"
grep -qx '  soak: stderr not empty: warning: ``` something odd' "$state/soak/verdict" ||
    fail "no note: $(cat "$state/soak/verdict")"
tail -n1 "$state/soak/verdict" | grep -q "^sim-cluster --soak: seeds 42..42" ||
    fail "the summary is not last: $(cat "$state/soak/verdict")"
if grep -q "second line" "$state/soak/verdict"; then fail "more than the first line"; fi

case_name="a soak that died"
soak crashed
expect "sim_cluster exited 134 on seed 42; recording a crash"
expect "sim-soak"
expect "integer overflow"
expect "zig-out/bin/sim_cluster 42 soak --soak-operations=300 --soak-epoch=100"
[ -f "$state/soak/last-1.log" ] || fail "the round before was not kept"

case_name="a soak killed by signal 9"
rm -f "$state/soak/verdict"
soak killed
expect "was killed (out of memory?): the host's, not reported"
refuse "recording a crash"
refuse "would file"
[ ! -f "$state/soak/verdict" ] || fail "a verdict was written"

case_name="a soak the runner refused"
soak refused
expect "sim_cluster exited 2 on seed 42 (its environment or arguments): not reported"
expect "--soak-epoch: not a number"
refuse "recording a crash"
[ ! -f "$state/soak/verdict" ] || fail "a verdict was written"

case_name="a second soak.sh while one holds the lock"
code=0
out=$(flock "$state/soak/lock" env SIM_FLEET_STATE_DIR="$state" SIM_FLEET_DRY_RUN=1 \
    SIM_SOAK_ROUNDS=1 sh "$here/soak.sh" 2>&1) || code=$?
[ "$code" -eq 2 ] || fail "exited $code: $out"
expect "another soak.sh holds $state/soak/lock; exiting"

case_name="no token and no dry run"
code=0
out=$(env -u CREDENTIALS_DIRECTORY -u SIM_FLEET_TOKEN_FILE SIM_FLEET_STATE_DIR="$state" \
    SIM_FLEET_DRY_RUN= sh "$here/soak.sh" 2>&1) || code=$?
[ "$code" -eq 2 ] || fail "exited $code: $out"
expect "no token: set SIM_FLEET_TOKEN_FILE"

case_name="a setting that is not a number"
code=0
out=$(SIM_FLEET_STATE_DIR=$state SIM_FLEET_DRY_RUN=1 SIM_SOAK_MINUTES=six \
    sh "$here/soak.sh" 2>&1) || code=$?
[ "$code" -eq 2 ] || fail "exited $code: $out"
expect "SIM_SOAK_MINUTES is 'six': it must be a number"
echo "test-soak: ok"
