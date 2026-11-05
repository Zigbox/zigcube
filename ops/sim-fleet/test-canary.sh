#!/bin/sh
# Checks run.sh's canary_round against fake fault-on runners and the real `sim_fleet ingest
# --dry-run`: a runner that fails as it must is counted and files nothing; one that passes is
# a would-be issue naming it; a crash, a missing runner and a draw that skips do nothing.
# Usage: test-canary.sh PATH-TO-sim_fleet (zig build sim-fleet-exe puts it in zig-out/bin).
set -eu
fleet=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
SIM_FLEET_SOURCE_ONLY=1
export SIM_FLEET_SOURCE_ONLY
. "$here/run.sh"
bin=$work/bin
round=$work/round
STATE=$work/state
built=abc123
SIM_FLEET_DRY_RUN=1
SIM_FLEET_REPORT_TIMEOUT=60
SIM_FLEET_CANARY_TIMEOUT=60
SIM_FLEET_CANARY_ONE_IN=1
SIM_FLEET_TRACKER=
token_file=
mkdir -p "$bin" "$round" "$STATE"
ln -s "$fleet" "$bin/sim_fleet"
# Every canary but sim_teeth is missing, so the pick may be any; a missing one logs and returns.
fake() { printf '#!/bin/sh\nexit %s\n' "$2" >"$bin/$1"; chmod +x "$bin/$1"; }
expect() {
    case "$out" in *"$1"*) ;; *) echo "FAIL ($case_name): wanted '$1' in: $out" >&2; exit 1 ;; esac
}
refuse() {
    case "$out" in *"$1"*) echo "FAIL ($case_name): unwanted '$1' in: $out" >&2; exit 1 ;; esac
}
for name in $CANARIES; do
    for exit_code in 0 1 139; do
        case_name="$name exit $exit_code"
        rm -f "$bin"/sim_*_teeth* "$bin/sim_teeth" "$STATE/state.txt.dry"
        fake "$name" "$exit_code"
        # Only this runner exists, so any pick that is not it is skipped: draw until it runs.
        out=""
        tries=0
        while [ "$tries" -lt 200 ]; do
            tries=$((tries + 1))
            out=$(canary_round 2>&1)
            case "$out" in *"not built"*) ;; *) break ;; esac
        done
        case "$exit_code" in
        0) expect "sim-canary"; expect "1 seeds, 0 failed"; refuse "would open" ;;
        1) expect "MISSED"; expect "stopped detecting: $name"; expect "1 seeds, 1 failed"
           expect "zig-out/bin/$name --seeds 1..10 100" ;;
        *) expect "exited $exit_code"; refuse "1 seeds" ;;
        esac
    done
done
case_name="draw skips"
SIM_FLEET_CANARY_ONE_IN=0
out=$(canary_round 2>&1)
[ -z "$out" ] || { echo "FAIL ($case_name): $out" >&2; exit 1; }
echo "canary round ok"
