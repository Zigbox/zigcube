#!/usr/bin/env bash
# Installs and configures Zigcube on one host of the Jepsen cluster from the tarball
# `zig build dist` makes (README.md says the order). Run as root; every command is idempotent and
# non-interactive: run again, it changes nothing unless its arguments changed.
#
#   zigcube.sh install TARBALL               check TARBALL against TARBALL.sha256, unpack it to
#                                            /opt/zigcube/<top>, point /opt/zigcube/current at
#                                            it, install the units and images.zon
#   zigcube.sh server STORE LISTEN           write server.zon (--listen LISTEN, store STORE)
#                                            and (re)start zcube-server if it changed or is not
#                                            running; then ca.crt and the admin client `jepsen`
#   zigcube.sh client-cert NAME [--replace]  an admin client certificate in $etc/client
#   zigcube.sh node-cert NAME [--replace]    a node certificate in $etc/nodes, to copy to NAME
#   zigcube.sh agent NAME SERVER CPU_MILLIS MEMORY_BYTES
#                                            write agent.zon and (re)start zcube-agent; the
#                                            harness has put ca.crt, node.crt and node.key in
#                                            $etc first (the server's ca.crt and nodes/NAME.*)
#
# STORE is the server's --store: for the battery, `postgres:host=PG1,PG2 port=5432,5432
# user=zcube dbname=postgres target_session_attrs=read-write`, so that libpq follows a promoted
# standby. LISTEN is an address every host reaches, e.g. `0.0.0.0:7070`.
#
# Settings (tests use them): ZCUBE_ETC (default /etc/zcube), ZCUBE_OPT (default /opt/zigcube),
# ZCUBE_VAR (default /var/lib), ZCUBE_SYSTEMCTL (default systemctl), ZCUBE_UNIT_DIR (default
# /etc/systemd/system).

set -euo pipefail

etc=${ZCUBE_ETC:-/etc/zcube}
opt=${ZCUBE_OPT:-/opt/zigcube}
var=${ZCUBE_VAR:-/var/lib}
systemctl=${ZCUBE_SYSTEMCTL:-systemctl}
unit_dir=${ZCUBE_UNIT_DIR:-/etc/systemd/system}
bin=$opt/current/bin
server_state=$var/zcube-server
agent_state=$var/zcube-agent
# How long `server` waits for a new server's CA certificate to appear.
ca_wait_tenths=300

die() {
    echo "zigcube.sh: $*" >&2
    exit 1
}

# A value placed between ZON quotes: refused if it could end the string.
zon_string() {
    case $1 in
        *'"'* | *\\* | *$'\n'*) die "a value may not hold a quote, backslash or newline: $1" ;;
    esac
    printf '"%s"' "$1"
}

is_number() {
    case $1 in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac
}

# Writes $2 to $1 if it differs; returns 0 if it wrote.
write_if_changed() {
    if [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; then return 1; fi
    printf '%s\n' "$2" > "$1.new"
    mv "$1.new" "$1"
}

# Restarts unit $1 if $2 is "changed" or it is not active.
converge() {
    if [ "$2" = changed ] || ! $systemctl is-active --quiet "$1"; then
        $systemctl restart "$1"
    fi
}

cmd_install() {
    [ $# -eq 1 ] || die "install needs TARBALL"
    local tarball=$1 name top
    name=$(basename "$tarball")
    top=${name%.tar.gz}
    [ "$top" != "$name" ] || die "$name is not a .tar.gz"
    [ -f "$tarball.sha256" ] || die "no $tarball.sha256 beside the tarball"
    (cd "$(dirname "$tarball")" && sha256sum --quiet -c "$name.sha256") ||
        die "$name does not match its SHA-256"
    local packages=(libsqlite3-0 libpq5 iptables)
    if ! dpkg -s "${packages[@]}" >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${packages[@]}" >/dev/null
    fi
    install -d "$opt" "$etc"
    if [ ! -d "$opt/$top" ]; then
        rm -rf "$opt/$top.new"
        install -d "$opt/$top.new"
        tar -xzf "$tarball" -C "$opt/$top.new"
        mv "$opt/$top.new/$top" "$opt/$top"
        rmdir "$opt/$top.new"
    fi
    ln -sfn "$top" "$opt/current"
    install -m 0644 "$opt/current/share/jepsen/images.zon" "$etc/images.zon"
    install -m 0644 "$opt/current/share/jepsen/zcube-server.service" "$unit_dir/"
    install -m 0644 "$opt/current/share/jepsen/zcube-agent.service" "$unit_dir/"
    $systemctl daemon-reload
}

server_config() {
    printf '%s\n' ".{" \
        "    .listen = $(zon_string "$2")," \
        "    .store = $(zon_string "$1")," \
        "    .create_store = true," \
        "    .state_dir = $(zon_string "$server_state")," \
        "}"
}

cmd_server() {
    [ $# -eq 2 ] || die "server needs STORE LISTEN"
    [ -x "$bin/zcube-server" ] || die "not installed: run install first"
    install -d -m 0700 "$server_state"
    local changed=same
    if write_if_changed "$etc/server.zon" "$(server_config "$1" "$2")"; then changed=changed; fi
    converge zcube-server "$changed"
    local tries=0 ca
    while true; do
        ca=$(find "$server_state" -maxdepth 1 -name 'ca-*.crt' ! -name 'ca-browser*' | head -n 1)
        [ -z "$ca" ] || break
        tries=$((tries + 1))
        [ $tries -le $ca_wait_tenths ] || die "no CA certificate in $server_state after 30 s"
        sleep 0.1
    done
    install -m 0644 "$ca" "$etc/ca.crt"
    issue client jepsen
}

# issue client|node NAME [--replace]: skips a certificate already there unless --replace.
issue() {
    local kind=$1 name=$2 replace=${3:-} dir
    [ -z "$replace" ] || [ "$replace" = --replace ] || die "unknown argument: $replace"
    [ -f "$etc/server.zon" ] || die "no $etc/server.zon: run server first"
    if [ "$kind" = client ]; then dir=$etc/client; else dir=$etc/nodes; fi
    install -d -m 0700 "$dir"
    if [ -z "$replace" ] && [ -f "$dir/$name.crt" ] && [ -f "$dir/$name.key" ]; then return 0; fi
    local flags=()
    if [ "$kind" = client ]; then flags+=(--scope admin); fi
    if [ -n "$replace" ]; then flags+=(--replace); fi
    "$bin/zcube-server" ca "issue-$kind" "$name" "${flags[@]}" --out "$dir" \
        --config "$etc/server.zon" >/dev/null
}

cmd_agent() {
    [ $# -eq 4 ] || die "agent needs NAME SERVER CPU_MILLIS MEMORY_BYTES"
    [ -x "$bin/zcube-agent" ] || die "not installed: run install first"
    is_number "$3" || die "CPU_MILLIS is not a number: $3"
    is_number "$4" || die "MEMORY_BYTES is not a number: $4"
    local file
    for file in ca.crt node.crt node.key; do
        [ -f "$etc/$file" ] || die "no $etc/$file: copy it from the server host first"
    done
    chmod 0600 "$etc/node.key"
    local config changed=same
    config=$(printf '%s\n' ".{" \
        "    .node = $(zon_string "$1")," \
        "    .server = $(zon_string "$2")," \
        "    .state_dir = $(zon_string "$agent_state")," \
        "    .cpu_millis = $3," \
        "    .memory_bytes = $4," \
        "    .images = $(zon_string "$etc/images.zon")," \
        "    .ca = $(zon_string "$etc/ca.crt")," \
        "    .cert = $(zon_string "$etc/node.crt")," \
        "    .key = $(zon_string "$etc/node.key")," \
        "}")
    if write_if_changed "$etc/agent.zon" "$config"; then changed=changed; fi
    converge zcube-agent "$changed"
}

[ "$(id -u)" = 0 ] || die "run as root"
[ $# -ge 1 ] || die "usage: zigcube.sh install|server|client-cert|node-cert|agent ..."
command=$1
shift
case $command in
    install) cmd_install "$@" ;;
    server) cmd_server "$@" ;;
    client-cert) [ $# -ge 1 ] || die "client-cert needs NAME"; issue client "$@" ;;
    node-cert) [ $# -ge 1 ] || die "node-cert needs NAME"; issue node "$@" ;;
    agent) cmd_agent "$@" ;;
    *) die "unknown command: $command" ;;
esac
