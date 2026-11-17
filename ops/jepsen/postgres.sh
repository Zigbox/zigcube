#!/usr/bin/env bash
# The Jepsen cluster's Postgres 16: a primary and a synchronous streaming standby, on two hosts.
# Modelled on `pg_dev pair-up sync` (src/pg_dev.zig), with what a real host needs added:
# listening on the network, `fsync` on, and pg_hba entries for the cluster's subnet. README.md
# says the order to run it in. Run as root; every command is idempotent and non-interactive.
#
#   postgres.sh install                       apt-get the Postgres 16 server (no cluster made)
#   postgres.sh primary --allow CIDR [--restart]
#                                             make (once) and start the primary; a primary
#                                             that exists but is stopped is started again only
#                                             with --restart (no standby was promoted meanwhile)
#   postgres.sh standby PRIMARY_HOST[:PORT] --allow CIDR [--rebuild]
#                                             make (once) and start the standby; --rebuild
#                                             deletes this host's data first (a crashed primary
#                                             rejoins this way, never as a primary)
#   postgres.sh sync-on                       on the primary: wait for the standby, require it
#   postgres.sh promote                       on the standby: promote it, alone and async
#   postgres.sh crash                         SIGKILL the postmaster and its children
#   postgres.sh status                        running? primary or standby? sync setting
#   postgres.sh down                          stop and delete the data
#
# Settings: ZCUBE_PG_DIR (default /var/lib/zcube-pg: `data/`, `role.conf`, `postgres.log`),
# ZCUBE_PG_PORT (default 5432), ZCUBE_PG_BIN (default /usr/lib/postgresql/16/bin).
#
# The synchronous settings live in `role.conf`, outside the data directory, which postgresql.conf
# includes: pg_basebackup copies the data directory only, so a standby never inherits them, and a
# promoted standby runs alone with nothing to wait for. `sync-on` writes them on the primary.

set -euo pipefail

dir=${ZCUBE_PG_DIR:-/var/lib/zcube-pg}
port=${ZCUBE_PG_PORT:-5432}
bin=${ZCUBE_PG_BIN:-/usr/lib/postgresql/16/bin}
data=$dir/data
role=$dir/role.conf
log=$dir/postgres.log
# The name the standby reports, and the one synchronous_standby_names lists (as pg_dev's).
standby_name=zcube_standby
# The Postgres store holds up to 80 connections (AGENTS.md, "Server limits"), and
# pg_basebackup and psql need a few more.
max_connections=200

die() {
    echo "postgres.sh: $*" >&2
    exit 1
}

as_postgres() {
    runuser -u postgres -- "$@"
}

running() {
    [ -f "$data/postmaster.pid" ] && as_postgres "$bin/pg_ctl" -D "$data" status >/dev/null 2>&1
}

sql() {
    as_postgres "$bin/psql" -h 127.0.0.1 -p "$port" -U zcube -d postgres -XAtq -c "$1"
}

start() {
    if running; then return 0; fi
    as_postgres "$bin/pg_ctl" -D "$data" -l "$log" -w -t 60 start >/dev/null
}

parse_allow() {
    allow=
    rebuild=false
    restart=false
    while [ $# -gt 0 ]; do
        case $1 in
            --allow) [ $# -ge 2 ] || die "--allow needs a CIDR"; allow=$2; shift 2 ;;
            --rebuild) rebuild=true; shift ;;
            --restart) restart=true; shift ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    [ -n "$allow" ] || die "--allow CIDR is required (the subnet the cluster's hosts are in)"
}

make_dir() {
    install -d -o postgres -g postgres -m 0700 "$dir"
    [ -f "$role" ] || as_postgres touch "$role"
}

# Settings for a data directory either role uses; written over on every run, so they converge.
configure() {
    local cidr=$1
    as_postgres tee "$data/zcube.conf" >/dev/null <<EOF
listen_addresses = '*'
port = $port
max_connections = $max_connections
unix_socket_directories = '$dir'
wal_level = replica
max_wal_senders = 10
hot_standby = on
wal_retrieve_retry_interval = '100ms'
include_if_exists = '$role'
EOF
    if ! grep -qx "include = 'zcube.conf'" "$data/postgresql.conf"; then
        echo "include = 'zcube.conf'" | as_postgres tee -a "$data/postgresql.conf" >/dev/null
    fi
    as_postgres tee "$data/pg_hba.conf" >/dev/null <<EOF
local all all trust
host all all 127.0.0.1/32 trust
host replication all 127.0.0.1/32 trust
host all zcube $cidr trust
host replication zcube $cidr trust
EOF
}

write_role() {
    printf '%s' "$1" | as_postgres tee "$role.new" >/dev/null
    mv "$role.new" "$role"
}

cmd_install() {
    if [ -x "$bin/pg_ctl" ]; then return 0; fi
    install -d /etc/postgresql-common
    if ! grep -q '^create_main_cluster' /etc/postgresql-common/createcluster.conf 2>/dev/null; then
        echo 'create_main_cluster = false' >> /etc/postgresql-common/createcluster.conf
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q postgresql-16 >/dev/null
    systemctl disable --now postgresql >/dev/null 2>&1 || true
}

cmd_primary() {
    parse_allow "$@"
    make_dir
    if [ -f "$data/standby.signal" ]; then
        die "$data is a standby's; a primary is made only on an empty host (down first)"
    fi
    if [ ! -f "$data/PG_VERSION" ]; then
        as_postgres "$bin/initdb" -D "$data" -A trust -U zcube >/dev/null
    elif ! running && ! $restart; then
        # A stopped primary may have crashed and had its standby promoted: started again, it
        # would be a second primary. It rejoins with `standby ... --rebuild`.
        die "this primary exists and is stopped: rejoin as a standby with" \
            "'standby NEW_PRIMARY --allow CIDR --rebuild', or --restart if no standby was promoted"
    fi
    configure "$allow"
    start
    as_postgres "$bin/pg_ctl" -D "$data" reload >/dev/null
}

cmd_standby() {
    [ $# -ge 1 ] || die "standby needs PRIMARY_HOST[:PORT]"
    local primary=${1%%:*} primary_port=$port
    case $1 in *:*) primary_port=${1#*:} ;; esac
    shift
    parse_allow "$@"
    make_dir
    if $rebuild; then
        if running; then as_postgres "$bin/pg_ctl" -D "$data" -m immediate -w stop >/dev/null; fi
        rm -rf "$data"
    fi
    if [ -f "$data/PG_VERSION" ] && [ ! -f "$data/standby.signal" ]; then
        die "$data is a primary's; rejoin as a standby with --rebuild"
    fi
    if [ ! -f "$data/PG_VERSION" ]; then
        rm -rf "$data"
        as_postgres "$bin/pg_basebackup" -D "$data" -R -X stream -c fast \
            -d "host=$primary port=$primary_port user=zcube application_name=$standby_name"
        chmod 0700 "$data"
    fi
    write_role ""
    configure "$allow"
    start
}

cmd_sync_on() {
    running || die "Postgres is not running here"
    [ "$(sql 'select pg_is_in_recovery()')" = f ] || die "sync-on runs on the primary"
    local tries=0
    while [ "$(sql "select count(*) from pg_stat_replication
        where application_name = '$standby_name' and state = 'streaming'")" != 1 ]; do
        tries=$((tries + 1))
        [ $tries -le 600 ] || die "no standby '$standby_name' streams after 60 s"
        sleep 0.1
    done
    write_role "synchronous_commit = remote_apply
synchronous_standby_names = '$standby_name'
"
    as_postgres "$bin/pg_ctl" -D "$data" reload >/dev/null
    tries=0
    while [ "$(sql "select sync_state from pg_stat_replication
        where application_name = '$standby_name'")" != sync ]; do
        tries=$((tries + 1))
        [ $tries -le 100 ] || die "the standby streams but is not synchronous after 10 s"
        sleep 0.1
    done
}

cmd_promote() {
    running || die "Postgres is not running here"
    write_role ""
    if [ "$(sql 'select pg_is_in_recovery()')" = t ]; then
        as_postgres "$bin/pg_ctl" -D "$data" -w -t 60 promote >/dev/null
    fi
    as_postgres "$bin/pg_ctl" -D "$data" reload >/dev/null
}

cmd_crash() {
    [ -f "$data/postmaster.pid" ] || return 0
    local pid children
    pid=$(head -n 1 "$data/postmaster.pid")
    kill -0 "$pid" 2>/dev/null || return 0
    # The children first in the list, the postmaster with them: a postmaster that outlived a
    # child's death would restart it, which is recovery, not a crash.
    children=$(pgrep -P "$pid" || true)
    # shellcheck disable=SC2086 # One pid per word.
    kill -KILL "$pid" $children
    # Until it is reaped, the postmaster's pid still answers `kill -0` and pg_ctl calls it running.
    local tries=0
    while kill -0 "$pid" 2>/dev/null; do
        tries=$((tries + 1))
        [ $tries -le 100 ] || die "the postmaster ($pid) is still there 10 s after SIGKILL"
        sleep 0.1
    done
}

cmd_status() {
    if ! running; then
        echo "stopped"
        return 0
    fi
    local recovery sync
    if ! recovery=$(sql 'select pg_is_in_recovery()' 2>/dev/null); then
        echo "not answering"
        return 0
    fi
    sync=$(sql 'show synchronous_standby_names')
    if [ "$recovery" = t ]; then echo "standby"; else echo "primary sync='$sync'"; fi
}

cmd_down() {
    if running; then as_postgres "$bin/pg_ctl" -D "$data" -m immediate -w stop >/dev/null; fi
    rm -rf "$dir"
}

[ "$(id -u)" = 0 ] || die "run as root"
[ $# -ge 1 ] || die "usage: postgres.sh install|primary|standby|sync-on|promote|crash|status|down"
command=$1
shift
case $command in
    install) cmd_install "$@" ;;
    primary) cmd_primary "$@" ;;
    standby) cmd_standby "$@" ;;
    sync-on) cmd_sync_on "$@" ;;
    promote) cmd_promote "$@" ;;
    crash) cmd_crash "$@" ;;
    status) cmd_status "$@" ;;
    down) cmd_down "$@" ;;
    *) die "unknown command: $command" ;;
esac
