#!/bin/sh
# Sets up the simulation fleet on a fresh Ubuntu 24.04 host (ops/sim-fleet/README.md). Run as
# root: `sh setup.sh [--token-file PATH] [--heartbeat-file PATH] [--ref BRANCH]`. Safe to run
# again. The service checkout ($HOME_DIR/zigcube, which the unit runs run.sh from and builds the
# fleet's own sim_fleet from) is set to BRANCH of the remote (default main), detached; run.sh
# never moves it, so this is how the fleet's own tools are updated (README.md, "Redeploy"). With
# --token-file the token is copied (never printed, never passed as an argument value) to
# /etc/sim-fleet/token, mode 0600; with --heartbeat-file the file holding the heartbeat URL (a
# secret too) is copied the same way to /etc/sim-fleet/heartbeat-url. Without it that file is
# left as it is, or created empty (no heartbeat; the unit also starts without it).
# It starts the service only when a token is present. It stops a running service first, so its
# build never races the service's, and starts it again at the end.
set -eu
# `su simfleet` keeps the working directory, which simfleet may not be allowed to read.
cd /

# Keep in step with build.zig.zon (minimum_zig_version), CI and .claude/hooks/session-start.sh.
ZIG_VERSION=0.17.0
ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
REMOTE=${SIM_FLEET_REMOTE:-https://github.com/Zigbox/zigcube}
HOME_DIR=/var/lib/sim-fleet
ZIG_DIR=/opt/zig-x86_64-linux-$ZIG_VERSION

TOKEN_SRC=""
HEARTBEAT_SRC=""
REF=main
usage="usage: setup.sh [--token-file PATH] [--heartbeat-file PATH] [--ref BRANCH]"
while [ $# -gt 0 ]; do
    case "$1" in
    --token-file)
        if [ $# -lt 2 ]; then
            echo "setup.sh: --token-file needs a path" >&2
            exit 1
        fi
        TOKEN_SRC=$2
        shift 2
        ;;
    --heartbeat-file)
        if [ $# -lt 2 ]; then
            echo "setup.sh: --heartbeat-file needs a path" >&2
            exit 1
        fi
        HEARTBEAT_SRC=$2
        shift 2
        ;;
    --ref)
        # Into a shell command below: the characters of a branch run.sh accepts, no leading '-'.
        case "${2:-}" in
        '' | -* | *[!A-Za-z0-9._/-]* | *..*)
            echo "setup.sh: --ref needs a branch name ([A-Za-z0-9._/-], no '..')" >&2
            exit 1
            ;;
        esac
        REF=$2
        shift 2
        ;;
    *)
        echo "$usage" >&2
        exit 1
        ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "setup.sh: run as root" >&2
    exit 1
fi

apt-get update -q
apt-get install -y -q git curl xz-utils ca-certificates libpq-dev libsqlite3-dev

if [ ! -x "$ZIG_DIR/zig" ]; then
    tmp=$(mktemp -d)
    curl -sSfL -o "$tmp/zig.tar.xz" \
        "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
    echo "$ZIG_SHA256  $tmp/zig.tar.xz" | sha256sum -c --quiet
    tar -xJf "$tmp/zig.tar.xz" -C /opt
    rm -rf "$tmp"
fi
ln -sf "$ZIG_DIR/zig" /usr/local/bin/zig

if ! id simfleet >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$HOME_DIR" --shell /usr/sbin/nologin simfleet
fi

if systemctl is-active --quiet sim-fleet.service; then
    echo "sim-fleet: stopping the service for the setup build"
    systemctl stop sim-fleet.service
fi

if [ ! -d "$HOME_DIR/zigcube/.git" ]; then
    su -s /bin/sh simfleet -c "git clone --quiet '$REMOTE' '$HOME_DIR/zigcube'"
fi
wanted=$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' "$HOME_DIR/zigcube/build.zig.zon")
if [ "$wanted" != "$ZIG_VERSION" ]; then
    echo "setup.sh: build.zig.zon wants Zig $wanted, this script installs $ZIG_VERSION" >&2
    exit 1
fi
# A first build of the fleet's own sim_fleet, as run.sh builds it at start (build_reporter), so
# the Zig package cache is warm and a broken host shows now, not at 3 a.m. The soaked branches
# are built in worktrees of their own by run.sh.
su -s /bin/sh simfleet -c "cd '$HOME_DIR/zigcube' && \
    timeout 300 git fetch --quiet origin 'refs/heads/$REF' && \
    git checkout --quiet --detach --force FETCH_HEAD && \
    zig build -Doptimize=ReleaseSafe --cache-dir '$HOME_DIR/state/zig-cache' \
        --prefix '$HOME_DIR/state/fleet' sim-fleet-exe"
su -s /bin/sh simfleet -c "cd '$HOME_DIR/zigcube' && \
    echo \"sim-fleet: the service checkout is at $REF (\$(git rev-parse --short HEAD))\""

mkdir -p /etc/sim-fleet
if [ ! -f /etc/sim-fleet/fleet.env ]; then
    cp "$HOME_DIR/zigcube/ops/sim-fleet/fleet.env.example" /etc/sim-fleet/fleet.env
fi
cp "$HOME_DIR/zigcube/ops/sim-fleet/sim-fleet.service" /etc/systemd/system/sim-fleet.service
systemctl daemon-reload
systemctl enable sim-fleet.service

# Keep the journal from filling the disk (160 GB host: 2 GB is plenty for this service's logs).
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=2G\n' >/etc/systemd/journald.conf.d/sim-fleet.conf
systemctl restart systemd-journald

if [ -n "$TOKEN_SRC" ]; then
    if [ ! -s "$TOKEN_SRC" ]; then
        echo "setup.sh: $TOKEN_SRC is missing or empty" >&2
        exit 1
    fi
    (umask 077 && cat "$TOKEN_SRC" >/etc/sim-fleet/token.new)
    chmod 600 /etc/sim-fleet/token.new
    mv /etc/sim-fleet/token.new /etc/sim-fleet/token
fi

# Copied, never printed: the URL is a secret (README.md, "Heartbeat").
if [ -n "$HEARTBEAT_SRC" ]; then
    if [ ! -s "$HEARTBEAT_SRC" ]; then
        echo "setup.sh: $HEARTBEAT_SRC is missing or empty" >&2
        exit 1
    fi
    (umask 077 && cat "$HEARTBEAT_SRC" >/etc/sim-fleet/heartbeat-url.new)
    chmod 600 /etc/sim-fleet/heartbeat-url.new
    mv /etc/sim-fleet/heartbeat-url.new /etc/sim-fleet/heartbeat-url
fi
if [ ! -e /etc/sim-fleet/heartbeat-url ]; then
    (umask 077 && : >/etc/sim-fleet/heartbeat-url)
fi
chmod 600 /etc/sim-fleet/heartbeat-url

if [ -s /etc/sim-fleet/token ]; then
    chmod 600 /etc/sim-fleet/token
    systemctl restart sim-fleet.service
    echo "sim-fleet: started; journalctl -u sim-fleet -f"
else
    echo "sim-fleet: installed, not started. Put the token in /etc/sim-fleet/token (README.md)," >&2
    echo "then: systemctl start sim-fleet" >&2
fi
