#!/bin/sh
# Tests guest.sh's `relay-logs` against fake state directories (run by `zig build test`): it must
# read the layout `--runtime zigbox` writes (<state>/zigbox/<name>/relay.log), print what the logs
# say, and fail when there is no relay.log at all, so the demo's "no ZC-E07xx line" check cannot
# pass for lack of a log.
set -u
here=$(dirname "$0")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0
check() { # description, condition result (0 = holds)
    if [ "$2" -ne 0 ]; then echo "FAIL: $1"; failures=$((failures + 1)); fi
}

# No state at all, and the fake runtime's layout: both must fail.
STATE="$tmp/empty" sh "$here/guest.sh" relay-logs >"$tmp/out" 2>&1
check "no state directory fails" $((! $? ))
mkdir -p "$tmp/fake/containers/a"
echo "ZC-E0702 hidden" >"$tmp/fake/containers/a/relay.log"
STATE="$tmp/fake" sh "$here/guest.sh" relay-logs >"$tmp/out" 2>&1
check "relay.log under containers/ is not where the zigbox runtime writes: fails" $((! $? ))

# The real layout: found, and its content is printed, so the demo's grep can see a failure.
mkdir -p "$tmp/real/zigbox/job" "$tmp/real/zigbox/bystander"
echo "ZC-E0701 upstream refused" >"$tmp/real/zigbox/job/relay.log"
: >"$tmp/real/zigbox/bystander/relay.log"
STATE="$tmp/real" sh "$here/guest.sh" relay-logs >"$tmp/out" 2>&1
check "the real layout passes" $?
grep -q "ZC-E0701 upstream refused" "$tmp/out"
check "its lines are printed" $?
grep -q "ok: 2 relay.log files" "$tmp/out"
check "both logs are counted" $?

[ "$failures" -eq 0 ] && echo "test-guest: ok"
exit "$failures"
