#!/bin/sh
# Checks run.sh's coverage feedback (bias_pick, coverage_add) against a fake `sim_cluster` that
# prints what the real one prints with `--seeds`, and the real `sim_fleet`:
# - an `auto` fleet biases one round in SIM_FLEET_BIAS_ONE_IN, each cluster kind to the profile
#   `sim_fleet bias` names, and its workers and replays run that profile;
# - every round's coverage lands in $STATE/coverage.txt, and a new commit starts it over;
# - a biased round's seeds are counted by the tracker like any other's;
# - a fixed SIM_FLEET_PROFILE, or SIM_FLEET_BIAS_ONE_IN=0, never biases.
# Usage: test-bias.sh PATH-TO-sim_fleet. Exits 1 on a failure.
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
KINDS="sim-cluster sim-c1"
SIM_FLEET_DRY_RUN=1
SIM_FLEET_REPORT_TIMEOUT=60
SIM_FLEET_BATCH_TIMEOUT=60
SIM_FLEET_CANARY_ONE_IN=0
SIM_FLEET_TRACKER=
SIM_FLEET_PROFILE=auto
SIM_FLEET_OPS=auto
SIM_FLEET_BIAS_ONE_IN=2
SIM_FLEET_WORKERS_CLUSTER=1
SIM_FLEET_WORKERS_C1=1
SIM_FLEET_BATCH_CLUSTER=4
SIM_FLEET_BATCH_C1=4
token_file=
mkdir -p "$bin" "$STATE/crashes"
ln -s "$fleet" "$bin/sim_fleet"
fail() { echo "FAIL ($case_name): $*" >&2; exit 1; }
expect() { case "$out" in *"$1"*) ;; *) fail "wanted '$1' in: $out" ;; esac; }
refuse() { case "$out" in *"$1"*) fail "unwanted '$1' in: $out" ;; esac; }

# The fake runner: its arguments go to $work/args; it prints one coverage line for the profile it
# was given (`mixed` when it draws), every seed passing, and the summary line.
cat >"$bin/sim_cluster" <<EOF
#!/bin/sh
echo "\$*" >>"$work/args"
range=\$2
a=\${range%..*}
b=\${range#*..}
n=\$((b - a + 1))
profile=mixed
prefix=sim-cluster
for arg in "\$@"; do
    case "\$arg" in
    --profile=auto) ;;
    --profile=*) profile=\${arg#--profile=} ;;
    --c1) prefix="sim-cluster --c1" ;;
    esac
done
echo "coverage: profile=\$profile seeds=\$n check.c0=\$n path.rare=0"
echo "\$prefix: seeds \$a..\$b, drawn operations: 0 of \$n failed"
EOF
chmod +x "$bin/sim_cluster"

round_out() {
    rm -f "$STATE/state.txt.dry" "$work/args"
    # In this shell, as the loop runs it: bias_pick counts rounds in a variable.
    run_round >"$work/out" 2>&1
    out=$(cat "$work/out")
    args=$(cat "$work/args")
}

case_name="round 1 draws"
round_out
case "$args" in *"--profile=auto"*) ;; *) fail "not drawn: $args" ;; esac
expect "4 seeds"
grep -q "^seeds sim-c1 mixed 4$" "$STATE/coverage.txt" || fail "no coverage: $(cat \
    "$STATE/coverage.txt")"
grep -q "^seeds sim-cluster mixed 4$" "$STATE/coverage.txt" || fail "no sim-cluster coverage"

case_name="round 2 is biased"
round_out
# Every profile but `mixed` has no seeds, so the first of them, `partitions`, runs.
expect "bias sim-cluster: partitions, which has run 0 seeds"
expect "bias sim-c1: partitions"
refuse "--profile=auto"
[ "$(grep -c -- "--c1 --profile=partitions" "$work/args")" -eq 1 ] || fail "c1: $args"
[ "$(grep -c -- "--profile=partitions" "$work/args")" -eq 2 ] || fail "args: $args"
[ "$(kind_flags sim-c1)" = "--c1 --profile=partitions" ] || fail "replay flags: $(kind_flags \
    sim-c1)"
# The tracker counts the biased round's seeds, per kind.
grep -q "^kind [0-9-]* sim-c1 4 0$" "$STATE/state.txt.dry" || fail "seeds not counted: $(cat \
    "$STATE/state.txt.dry")"
grep -q "^seeds sim-c1 partitions 4$" "$STATE/coverage.txt" || fail "no biased coverage"

case_name="round 3 draws again"
round_out
case "$args" in *"--profile=partitions"*) fail "still biased: $args" ;; esac
[ "$(kind_flags sim-cluster)" = "--profile=auto" ] || fail "flags: $(kind_flags sim-cluster)"

case_name="a new commit starts the coverage over"
built=def456
mkdir -p "$STATE/bin/$built"
ln -s "$bin" "$STATE/bin/$built/bin"
bin=$STATE/bin/$built/bin
round_out
expect "bias sim-c1: mixed, which has run 0 seeds"
grep -q "^coverage 1 def456$" "$STATE/coverage.txt" || fail "header: $(head -n1 \
    "$STATE/coverage.txt")"
[ "$(grep -c "^seeds" "$STATE/coverage.txt")" -eq 2 ] || fail "old seeds kept"

case_name="a fixed profile never biases"
SIM_FLEET_PROFILE=skew
round_out
round_out
refuse "bias sim-"
case "$args" in *"--profile=skew"*) ;; *) fail "not skew: $args" ;; esac

case_name="0 never biases"
SIM_FLEET_PROFILE=auto
SIM_FLEET_BIAS_ONE_IN=0
round_out
round_out
refuse "bias sim-"
echo "coverage feedback biases one round in N"
