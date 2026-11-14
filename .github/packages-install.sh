#!/usr/bin/env bash
# Installs the Zigcube packages in a clean container, with the distro's own package tool, and
# checks what a user would: the files, the binaries, a flavour swap, an edited configuration that
# survives a reinstall, a remove. Shell because it drives apt and dnf (docs/STYLE.md: a `.sh` file
# needs a written reason; this is it). Run by CI's `packages` job: /p is zig-out/packages, built
# with the fixed test key, so signatures are not checked here (release-sign-test.sh and the
# release job check them against a real gpg key). zigbox-dev is not installed: it needs the
# zigbox package from zigbox.org, which the release job's verify step installs.
set -euo pipefail

fail() { echo "packages-install: $*" >&2; exit 1; }
arch=$(uname -m)
if command -v apt-get > /dev/null; then
  kind=deb
  [ "$arch" = x86_64 ] && darch=amd64 || darch=arm64
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq > /dev/null
  pkg() { printf '/p/apt/pool/main/z/%s/%s_0.0.0_%s.deb' "$1" "$1" "$darch"; }
  install() { apt-get install -y -qq --allow-downgrades "$@" > /dev/null; }
  reinstall() { apt-get install -y -qq --reinstall "$@" > /dev/null; }
  remove() { apt-get remove -y -qq "$@" > /dev/null; }
else
  kind=rpm
  pkg() { printf '/p/rpm/zigcube/%s/%s-0.0.0-1.%s.rpm' "$arch" "$1" "$arch"; }
  install() { dnf -y -q install --nogpgcheck "$@" > /dev/null; }
  reinstall() { dnf -y -q reinstall --nogpgcheck "$@" > /dev/null; }
  remove() { dnf -y -q remove "$@" > /dev/null; }
fi

# The server needs its store library; the packages do not pull one in (docs/briefs/packaging.md).
if [ "$kind" = deb ]; then apt-get install -y -qq libsqlite3-0 libpq5 > /dev/null
else dnf -y -q install sqlite-libs libpq > /dev/null; fi

install "$(pkg zigcube)" "$(pkg zigcube-server-sqlite)" "$(pkg zigcube-agent)"
zcube version > /dev/null || fail "zcube version failed"
version=$(zcube-server --version)
[ "${version%% *}" = zcube-server ] || fail "zcube-server --version said: $version"
for file in /etc/zigcube/server.zon /etc/zigcube/agent.zon \
  /usr/lib/systemd/system/zcube-server.service /usr/lib/systemd/system/zcube-agent.service; do
  [ -f "$file" ] || [ -f "/lib/systemd/system/${file##*/}" ] || fail "missing $file"
done
# Units ship disabled: nothing is enabled or started by the install.
if ls /etc/systemd/system/*.wants/zcube-* > /dev/null 2>&1; then fail "a unit was enabled"; fi

# The server starts on the shipped configuration (state directory as systemd's StateDirectory).
mkdir -p -m 0700 /var/lib/zigcube
zcube-server --config /etc/zigcube/server.zon > /tmp/server.log 2>&1 &
server=$!
sleep 3
kill -0 "$server" 2> /dev/null || { cat /tmp/server.log >&2; fail "the server did not stay up"; }
kill "$server"; wait "$server" 2> /dev/null || true

# Swapping the flavour replaces the other package (both provide zigcube-server).
install "$(pkg zigcube-server-postgres)"
if [ "$kind" = deb ]; then
  state=$(dpkg-query -W -f='${db:Status-Abbrev}' zigcube-server-sqlite 2> /dev/null || true)
  [ "${state:0:2}" != ii ] || fail "sqlite flavour stayed"
else rpm -q zigcube-server-sqlite > /dev/null 2>&1 && fail "sqlite flavour stayed"; fi
refusal=$(zcube-server --store sqlite:/tmp/x.db 2>&1 || true)
grep -q 'ZC-E0217' <<< "$refusal" || fail "no ZC-E0217 from the postgres flavour: $refusal"
install "$(pkg zigcube-server-sqlite)"

# An edited configuration survives a reinstall.
echo '// edited by the administrator' >> /etc/zigcube/server.zon
reinstall "$(pkg zigcube-server-sqlite)"
grep -q 'edited by the administrator' /etc/zigcube/server.zon || fail "reinstall overwrote server.zon"

remove zigcube-agent zigcube-server-sqlite zigcube
[ ! -e /usr/bin/zcube ] || fail "/usr/bin/zcube is still there after remove"
echo "packages-install: $kind ok"
