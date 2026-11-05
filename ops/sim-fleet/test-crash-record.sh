#!/bin/sh
# Checks that a crash record run.sh writes is read back by `sim_fleet ingest --dry-run`, for each
# kind, with a drawn and a fixed operation count. Usage: test-crash-record.sh PATH-TO-sim_fleet
# (zig build sim-fleet-exe puts it in zig-out/bin). Prints the dry run's lines; exits 1 on a miss.
set -eu
fleet=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
SIM_FLEET_SOURCE_ONLY=1
export SIM_FLEET_SOURCE_ONLY
. "$here/run.sh"
round=$work
SIM_FLEET_PROFILE=auto
for ops in auto 100; do
    SIM_FLEET_OPS=$ops
    for kind in sim-cluster sim-c1 sim-swarm; do
        # What --trace-steps leaves on stderr before a panic in the step "convergence".
        {
            echo "  replay: zig-out/bin/sim_cluster 77 120 5 --c1 --profile=crash_heavy" \
                "--lease-ttl-ms=8500 --replicas-pct=200 --heal-at=90"
            echo "step: faults"
            echo "step: convergence"
            echo "thread 1 panic: reached unreachable code"
        } >"$round/one.err"
        crash_record 77 134 "$kind" >"$work/record"
        if ! grep -q "^  replay: " "$work/record"; then echo "no replay: $kind" >&2; exit 1; fi
        out=$("$fleet" ingest --kind "$kind" --commit abc123 --state "$work/state" --dry-run \
            <"$work/record")
        echo "$kind ops=$ops: $out" | head -n 3
        case "$out" in
        *"1 seeds, 1 failed"*) ;;
        *) echo "dry run did not read the record: $kind ops=$ops" >&2; exit 1 ;;
        esac
    done
done
echo "crash records round-trip"
