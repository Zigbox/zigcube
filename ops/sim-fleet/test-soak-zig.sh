#!/bin/sh
# The fake `zig` of test-soak.sh ($WORK is its scratch directory). `zig build -l` lists the steps
# of the commit checked out where it runs: none (exit 1) for a commit listed in $WORK/broken, no
# sim-cluster-exe for one in $WORK/no-cluster. A build appends where it ran and its arguments to
# $WORK/builds and installs into its --prefix: for sim-cluster-exe a sim_cluster that prints a
# passing batch, or exits with the code in $WORK/producer-code; for sim-swarm-exe a sim_swarm;
# for sim-fleet-exe in the service checkout ($WORK/checkout) the fleet's reporter, which appends
# its arguments to $WORK/fleet-args and exits with the code in $WORK/ingest-code (ingest) or 0.
# Any other build also leaves a soaked commit's own sim_fleet, an old one that rejects what the
# fleet passes now (--ref, state v4, heartbeat) and appends to $WORK/soaked-fleet-ran: run.sh
# must never run it.
set -eu
commit=$(git rev-parse HEAD)
case " $* " in
*" -l "*)
    if grep -qx "$commit" "$WORK/broken"; then exit 1; fi
    if ! grep -qx "$commit" "$WORK/no-cluster"; then echo "  sim-cluster-exe  Install"; fi
    echo "  sim-swarm-exe    Install"
    echo "  sim-fleet-exe    Install"
    exit 0
    ;;
esac
args=" $* "
echo "$PWD $*" >>"$WORK/builds"
prefix=""
while [ $# -gt 0 ]; do
    if [ "$1" = --prefix ]; then prefix=$2; fi
    shift
done
mkdir -p "$prefix/bin"
case "$args" in
*" sim-cluster-exe "*)
    cat >"$prefix/bin/sim_cluster" <<'END'
#!/bin/sh
code=$(cat "$WORK/producer-code" 2>/dev/null || echo 0)
if [ "$code" -ne 0 ]; then exit "$code"; fi
printf 'sim-cluster: seeds %s, drawn operations: 0 of 3 failed\n' "$2"
END
    ;;
esac
case "$args" in
*" sim-swarm-exe "*) printf '#!/bin/sh\nexit 0\n' >"$prefix/bin/sim_swarm" ;;
esac
if [ "$PWD" = "$WORK/checkout" ]; then
    case "$args" in
    *" sim-fleet-exe "*)
        cat >"$prefix/bin/sim_fleet" <<'END'
#!/bin/sh
echo "$*" >>"$WORK/fleet-args"
if [ "$1" = ingest ]; then cat >/dev/null; exit "$(cat "$WORK/ingest-code")"; fi
exit 0
END
        ;;
    esac
else
    cat >"$prefix/bin/sim_fleet" <<'END'
#!/bin/sh
echo "$*" >>"$WORK/soaked-fleet-ran"
echo "sim-fleet: unknown option" >&2
exit 1
END
fi
chmod +x "$prefix"/bin/*
