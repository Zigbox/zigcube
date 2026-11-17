#!/usr/bin/env bash
# Tests postgres.sh and fault.sh's Postgres pause on one host, a primary and a standby on two
# ports in a scratch directory: the primary made, idempotently; the standby streamed and made
# synchronous (a write is on it at once); `fault.sh pause postgres` stops the postmaster and every
# child (a query times out) and `resume` answers again; given the four executables,
# test-recipe.sh against the pair with the battery's settings (both hosts,
# target_session_attrs=read-write); then the primary crashed, the standby promoted, the old
# primary refused as a primary and rebuilt as a standby of the new one, and both taken down.
#
# usage: test-postgres.sh [ZCUBE ZCUBE_SERVER ZCUBE_AGENT ZCUBE_JEPSEN_CLIENT]
# As root, with the Postgres 16 programs in ZCUBE_PG_BIN (default /usr/lib/postgresql/16/bin)
# and a `postgres` user. CI's jepsen job runs it on the tarball's executables.

set -euo pipefail

[ $# -eq 0 ] || [ $# -eq 4 ] || { echo "usage: test-postgres.sh [ZCUBE ZCUBE_SERVER" \
    "ZCUBE_AGENT ZCUBE_JEPSEN_CLIENT]" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "test-postgres.sh: run as root" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
bin=${ZCUBE_PG_BIN:-/usr/lib/postgresql/16/bin}
[ -x "$bin/pg_ctl" ] || { echo "test-postgres.sh: no Postgres 16 in $bin" >&2; exit 2; }

tmp=$(mktemp -d /tmp/zcube-pg-recipe.XXXXXX)
# The postgres user makes its directories in here.
chmod 0755 "$tmp"
# Below the ephemeral range, and apart from test-recipe.sh's ports (20000 to 28999).
port_a=$((29000 + $$ % 1800 * 2))
port_b=$((port_a + 1))
allow=127.0.0.1/32

on_a() { ZCUBE_PG_DIR=$tmp/a ZCUBE_PG_PORT=$port_a "$here/postgres.sh" "$@"; }
on_b() { ZCUBE_PG_DIR=$tmp/b ZCUBE_PG_PORT=$port_b "$here/postgres.sh" "$@"; }
sql() {
    runuser -u postgres -- "$bin/psql" -h 127.0.0.1 -p "$1" -U zcube -d postgres -XAtq -c "$2"
}
fail() {
    echo "test-postgres.sh: FAIL: $*" >&2
    local log
    for log in "$tmp"/a/postgres.log "$tmp"/b/postgres.log; do
        if [ -f "$log" ]; then tail -n 5 "$log" >&2; fi
    done
    exit 1
}
cleanup() {
    ZCUBE_PG_DIR=$tmp/a "$here/fault.sh" resume postgres >/dev/null 2>&1 || true
    on_a down >/dev/null 2>&1 || true
    on_b down >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT

expect_status() {
    local got
    got=$("on_$1" status) || fail "status on $1"
    [ "$got" = "$2" ] || fail "$1 is '$got', not '$2'"
}

on_a primary --allow "$allow" || fail "primary"
on_a primary --allow "$allow" || fail "primary, again"
on_b standby "127.0.0.1:$port_a" --allow "$allow" || fail "standby"
on_a sync-on || fail "sync-on"
expect_status a "primary sync='zcube_standby'"
expect_status b standby
# remote_apply: a committed write is visible on the standby when the commit returns.
sql "$port_a" "create table t (x int); insert into t values (1)" || fail "a write"
[ "$(sql "$port_b" "select count(*) from t")" = 1 ] || fail "the write is not on the standby"

# Pause: the postmaster and every child stopped (state T), a query waits until resumed.
sql "$port_a" "select 1" >/dev/null || fail "a query"
ZCUBE_PG_DIR=$tmp/a "$here/fault.sh" pause postgres || fail "pause postgres"
postmaster=$(head -n 1 "$tmp/a/data/postmaster.pid")
for pid in "$postmaster" $(pgrep -P "$postmaster"); do
    case $(ps -o stat= -p "$pid" || echo gone) in T* | gone) ;; *) fail "$pid runs on" ;; esac
done
status=0
timeout 3 runuser -u postgres -- "$bin/psql" -h 127.0.0.1 -p "$port_a" -U zcube -d postgres \
    -XAtq -c "select 1" >/dev/null 2>&1 || status=$?
[ "$status" = 124 ] || fail "a query to a paused Postgres ended with $status, not the timeout"
ZCUBE_PG_DIR=$tmp/a "$here/fault.sh" resume postgres || fail "resume postgres"
[ "$(sql "$port_a" "select 1")" = 1 ] || fail "a query after resume"

if [ $# -eq 4 ]; then
    ZCUBE_RECIPE_POSTGRES="host=127.0.0.1,127.0.0.1 port=$port_a,$port_b user=zcube \
dbname=postgres target_session_attrs=read-write" bash "$here/test-recipe.sh" "$@" ||
        fail "test-recipe.sh on the pair"
fi

# Failover: the primary crashed, the standby promoted, alone and async.
on_a crash || fail "crash"
expect_status a stopped
on_b promote || fail "promote"
expect_status b "primary sync=''"
sql "$port_b" "insert into t values (2)" || fail "a write on the promoted standby"
# The old primary may not come back as a primary; it rejoins as a standby.
if on_a primary --allow "$allow" >/dev/null 2>&1; then fail "a crashed primary started again"; fi
on_a standby "127.0.0.1:$port_b" --allow "$allow" --rebuild || fail "rebuild as a standby"
expect_status a standby
on_b sync-on || fail "sync-on on the new primary"
expect_status b "primary sync='zcube_standby'"
[ "$(sql "$port_a" "select count(*) from t")" = 2 ] || fail "the rebuilt standby lacks a write"

on_a down || fail "down"
on_b down || fail "down"
[ ! -e "$tmp/a" ] && [ ! -e "$tmp/b" ] || fail "down left its directory"
echo "test-postgres.sh: PASS"
