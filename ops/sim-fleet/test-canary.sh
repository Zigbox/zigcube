#!/bin/sh
# Checks run.sh's teeth canary (canary_pick, the canary worker, canary_report) against fake
# fault-on runners that print what the real ones print, and the real `sim_fleet ingest
# --dry-run`, over the manifest `zig build sim-canary-exe` installs:
# - the canaries run in the manifest's order, one every SIM_FLEET_CANARY_ONE_IN rounds;
# - a canary that fails with its symptom is "caught" and files nothing;
# - a miss (no seed failed), a wrong symptom, a crash (signal; replayed seed by seed) and a run
#   that refused its arguments are each filed, and the run's output is kept;
# - a canary whose report was not filed runs again next round.
# Usage: test-canary.sh PATH-TO-sim_fleet PATH-TO-canaries.txt. Exits 1 on a failure.
set -eu
fleet=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
manifest_in=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
SIM_FLEET_SOURCE_ONLY=1
export SIM_FLEET_SOURCE_ONLY
. "$here/run.sh"
STATE=$work/state
built=abc123
bin=$STATE/bin/$built/bin
KINDS=""
SIM_FLEET_DRY_RUN=1
SIM_FLEET_REPORT_TIMEOUT=60
SIM_FLEET_BATCH_TIMEOUT=60
SIM_FLEET_CANARY_ONE_IN=1
SIM_FLEET_TRACKER=
SIM_FLEET_PROFILE=auto
SIM_FLEET_OPS=auto
token_file=
mkdir -p "$bin" "$STATE/bin/$built/share/sim-fleet" "$STATE/crashes"
manifest=$STATE/bin/$built/share/sim-fleet/canaries.txt
cp "$manifest_in" "$manifest"
ln -s "$fleet" "$bin/sim_fleet"
fail() { echo "FAIL ($case_name): $*" >&2; exit 1; }
expect() { case "$out" in *"$1"*) ;; *) fail "wanted '$1' in: $out" ;; esac; }
refuse() { case "$out" in *"$1"*) fail "unwanted '$1' in: $out" ;; esac; }

# A fake runner prints, for its seeds A..B, what $work/mode asks: `caught` (seed A fails with the
# symptom), `wrong` (seed A fails with another check), `missed` (no seed fails), `crash` (killed
# by a signal), `refuse` (exit 2).
fake() { # runner kind symptom
    case "$2" in
    sim-swarm) sim=sim_swarm prefix=sim-swarm step=fetch c1="" ;;
    sim-c1) sim=sim_cluster prefix="sim-cluster --c1" step=faults c1=" --c1" ;;
    *) sim=sim_cluster prefix=sim-cluster step=faults c1="" ;;
    esac
    check=$3
    if [ "$check" = - ]; then check="the fault was seen"; fi
    cat >"$bin/$1" <<EOF
#!/bin/sh
range=\$2
a=\${range%..*}
b=\${range#*..}
n=\$((b - a + 1))
case "\$(cat "$work/mode")" in
caught | wrong)
    check="$check"
    if [ "\$(cat "$work/mode")" = wrong ]; then check="I6: an allocation disagrees"; fi
    printf 'seed %s: FAILED: %s\n  step: $step\n' "\$a" "\$check"
    printf '  replay: zig-out/bin/$sim %s 40 3$c1\n' "\$a"
    printf '$prefix: seeds %s..%s, drawn operations: 1 of %s failed\n' "\$a" "\$b" "\$n"
    exit 1
    ;;
missed)
    printf '$prefix: seeds %s..%s, drawn operations: 0 of %s failed\n' "\$a" "\$b" "\$n"
    ;;
crash)
    echo "thread 1 panic: reached unreachable code" >&2
    kill -SEGV \$\$
    ;;
*)
    echo "error: bad argument" >&2
    exit 2
    ;;
esac
EOF
    chmod +x "$bin/$1"
}

runners=""
count=0
while read -r runner kind seeds symptom; do
    case "$runner" in '' | '#'*) continue ;; esac
    fake "$runner" "$kind" "$symptom"
    runners="$runners $runner"
    count=$((count + 1))
    case "$seeds" in '' | *[!0-9]*) case_name=manifest; fail "bad seeds for $runner" ;; esac
done <"$manifest"
case_name=manifest
[ "$count" -ge 8 ] || fail "only $count canaries in $manifest"

round_out() {
    rm -f "$STATE/state.txt.dry"
    out=$(run_round 2>&1)
}

# The cycle: every runner once, in the manifest's order, then the first again.
echo caught >"$work/mode"
for runner in $runners; do
    case_name="cycle $runner"
    round_out
    expect "canary $runner on seeds"
    expect "sim-fleet: canary $runner: caught"
    refuse "would file"
done
case_name="cycle wraps"
round_out
first=$(echo $runners | cut -d" " -f1)
expect "canary $first on seeds"
[ -z "$(ls "$STATE/crashes")" ] || fail "a caught canary kept its output"

# One round in two.
case_name="one in two"
SIM_FLEET_CANARY_ONE_IN=2
round_out
refuse "canary"
round_out
expect "canary"
SIM_FLEET_CANARY_ONE_IN=1

# A canary with a symptom, and the swarm's.
wedge=$(grep '^sim_c1_teeth_wedge ' "$manifest" | cut -d' ' -f1)
[ -n "$wedge" ] || { case_name=manifest; fail "no sim_c1_teeth_wedge"; }
at() { # The cycle's place of runner $1.
    grep -v '^#' "$manifest" | grep -n "^$1 " | cut -d: -f1 | awk '{print $1 - 1}' \
        >"$STATE/canary-next"
}
for runner in sim_c1_teeth_wedge sim_swarm_teeth; do
    for mode in missed wrong crash refuse; do
        case_name="$runner $mode"
        echo "$mode" >"$work/mode"
        rm -f "$STATE/crashes"/*
        at "$runner"
        before=$(cat "$STATE/canary-next")
        round_out
        case "$mode" in
        missed) expect "$runner: MISSED"; expect "stopped detecting: $runner failed no seed" ;;
        wrong)
            if [ "$runner" = sim_swarm_teeth ]; then
                expect "$runner: caught" # No symptom: any check is the fault's.
                continue
            fi
            expect "$runner: WRONG SYMPTOM"; expect "but never with"
            ;;
        crash) expect "$runner: CRASHED"; expect "replaying them one by one" ;;
        *)
            expect "$runner: CRASHED"
            expect "crash: exited N: error: bad argument (step: canary)"
            ;;
        esac
        expect "would file"
        [ "$(cat "$STATE/canary-next")" -eq $((before + 1)) ] || fail "the cycle did not move"
        ls "$STATE/crashes" | grep -q "canary-$runner" || fail "its output was not kept"
    done
done

# Not filed: the reporter failed, so the same canary runs again next round.
case_name="not filed"
echo missed >"$work/mode"
at sim_c1_teeth_wedge
before=$(cat "$STATE/canary-next")
rm "$bin/sim_fleet"
printf '#!/bin/sh\necho "sim-fleet: GitHub asked to wait"\nexit 2\n' >"$bin/sim_fleet"
chmod +x "$bin/sim_fleet"
round_out
expect "was not filed; it runs again next round"
[ "$(cat "$STATE/canary-next")" -eq "$before" ] || fail "the cycle moved"
rm "$bin/sim_fleet"
ln -s "$fleet" "$bin/sim_fleet"
round_out
expect "canary sim_c1_teeth_wedge on seeds"
expect "sim_c1_teeth_wedge: MISSED"
echo "canary ok: $count runners"
