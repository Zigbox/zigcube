#!/bin/sh
# Sets up the simulation fleet on a fresh Ubuntu 24.04 host (ops/sim-fleet/README.md). Run as
# root: `sh setup.sh`. Safe to run again. It starts the service only when a token is present.
set -eu

# Keep in step with build.zig.zon (minimum_zig_version), CI and .claude/hooks/session-start.sh.
ZIG_VERSION=0.17.0
ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
REMOTE=${SIM_FLEET_REMOTE:-https://github.com/Zigbox/zigcube}
HOME_DIR=/var/lib/sim-fleet
ZIG_DIR=/opt/zig-x86_64-linux-$ZIG_VERSION

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

if [ ! -d "$HOME_DIR/zigcube/.git" ]; then
    su -s /bin/sh simfleet -c "git clone --quiet '$REMOTE' '$HOME_DIR/zigcube'"
fi
wanted=$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' "$HOME_DIR/zigcube/build.zig.zon")
if [ "$wanted" != "$ZIG_VERSION" ]; then
    echo "setup.sh: build.zig.zon wants Zig $wanted, this script installs $ZIG_VERSION" >&2
    exit 1
fi
# A first build, so the Zig package cache is warm and a broken host shows now, not at 3 a.m.
su -s /bin/sh simfleet -c "cd '$HOME_DIR/zigcube' && git fetch --quiet origin main && \
    git checkout --quiet --detach FETCH_HEAD && \
    zig build -Doptimize=ReleaseSafe sim-cluster-exe sim-fleet-exe"

mkdir -p /etc/sim-fleet
if [ ! -f /etc/sim-fleet/fleet.env ]; then
    cp "$HOME_DIR/zigcube/ops/sim-fleet/fleet.env.example" /etc/sim-fleet/fleet.env
fi
cp "$HOME_DIR/zigcube/ops/sim-fleet/sim-fleet.service" /etc/systemd/system/sim-fleet.service
systemctl daemon-reload
systemctl enable sim-fleet.service

if [ -s /etc/sim-fleet/token ]; then
    chmod 600 /etc/sim-fleet/token
    systemctl restart sim-fleet.service
    echo "sim-fleet: started; journalctl -u sim-fleet -f"
else
    echo "sim-fleet: installed, not started. Put the token in /etc/sim-fleet/token (README.md)," >&2
    echo "then: systemctl start sim-fleet" >&2
fi
