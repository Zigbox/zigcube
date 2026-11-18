#!/usr/bin/env bash
# The libraries `zig build release` links the aarch64 zcube-server against, on an x86_64 Ubuntu
# 24.04 host (a GitHub runner): libsqlite3 and libpq for arm64 from Ubuntu's ports archive, through
# multiarch, and qemu-user, which release-check.sh runs the aarch64 binaries under. Writes DIR with
# two links, libsqlite3.so and libpq.so, to the arm64 shared libraries (libpq-dev cannot be
# installed for two architectures at once, so the arm64 libpq.so link is made here) and prints
# DIR. Pass it as `zig build release -Drelease-lib-dir-aarch64=DIR`. The x86_64 build links the
# host's own libraries from /usr/lib/x86_64-linux-gnu, which this installs too.
#
# Usage, as root: release-libs.sh DIR. Used by release.yml's `build` job and ci.yml's `release`
# job (docs/releases/automation.md). Reads and writes nothing secret.
set -euo pipefail

fail() { echo "release-libs: $1" >&2; exit 1; }

dir=${1:-}
[ -n "$dir" ] || fail "usage: release-libs.sh DIR"
[ "$(id -u)" = 0 ] || fail "run as root"
# shellcheck disable=SC1091
. /etc/os-release
[ "${VERSION_CODENAME:-}" = noble ] || fail "needs Ubuntu 24.04 (noble), not ${PRETTY_NAME:-?}"
[ "$(dpkg --print-architecture)" = amd64 ] || fail "needs an amd64 host"

# The public archive instead of the runner's Azure mirror, as .github/actions/install-apt does.
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
  [ -f "$f" ] || continue
  sed -i -E \
    -e 's#(mirror\+file:/etc/apt/apt-mirrors\.txt|https?://azure\.archive\.ubuntu\.com/ubuntu/?)#http://archive.ubuntu.com/ubuntu/#g' \
    -e 's#https?://security\.ubuntu\.com/ubuntu/?#http://security.ubuntu.com/ubuntu/#g' "$f"
done
rm -f /etc/apt/apt-mirrors.txt

# archive.ubuntu.com serves amd64 only and ports.ubuntu.com serves arm64, so every Ubuntu source
# names its architecture. A stanza that already names one is left as it is.
src=/etc/apt/sources.list.d/ubuntu.sources
[ -f "$src" ] || fail "no $src (an Ubuntu 24.04 image has one)"
stanzas=$(grep -c '^Types:' "$src" || true)
named=$(grep -c '^Architectures:' "$src" || true)
if [ "$named" = 0 ]; then
  sed -i 's/^Types: deb$/Types: deb\nArchitectures: amd64/' "$src"
elif [ "$named" != "$stanzas" ]; then
  fail "$src names an architecture in $named of $stanzas stanzas; edit it by hand"
fi
if grep -q '^deb http' /etc/apt/sources.list 2> /dev/null; then
  sed -i 's/^deb http/deb [arch=amd64] http/' /etc/apt/sources.list
fi
cat > /etc/apt/sources.list.d/ubuntu-ports-arm64.sources << 'SOURCES'
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: noble noble-updates noble-security
Components: main universe
Architectures: arm64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
dpkg --add-architecture arm64

# libpq5 is Multi-Arch: same, so its amd64 and arm64 versions must be equal. The runner image
# installs libpq5 from apt.postgresql.org (PGDG), which ports.ubuntu.com cannot match for arm64
# (CI job 134461192114: amd64 18.6 against arm64 16.15). So PGDG's sources go, and both
# architectures take the newest version Ubuntu serves for both, downgrading the host's if needed:
# the release links Ubuntu 24.04's libpq, as docs/releases/automation.md says.
for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [ -f "$f" ] || continue
  if grep -q 'apt\.postgresql\.org' "$f"; then
    echo "release-libs: removing $f (apt.postgresql.org)"
    rm -f "$f"
  fi
done
if grep -q 'apt\.postgresql\.org' /etc/apt/sources.list 2> /dev/null; then
  sed -i '/apt\.postgresql\.org/d' /etc/apt/sources.list
fi

opts=(-o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 -o Acquire::Retries=2)
timeout 300 apt-get "${opts[@]}" update -q
versions() { apt-cache madison "$1" | awk -F'|' '{gsub(/ /, "", $2); print $2}' | sort -u; }
pq=$(comm -12 <(versions libpq5:amd64) <(versions libpq5:arm64) | sort -V | tail -n 1)
[ -n "$pq" ] || fail "no libpq5 version is served for both amd64 and arm64"
timeout 600 apt-get "${opts[@]}" install -y -q --no-install-recommends --allow-downgrades \
  libsqlite3-dev libsqlite3-dev:arm64 "libpq5=$pq" "libpq-dev=$pq" "libpq5:arm64=$pq" qemu-user
# What the release linked, for whoever reproduces it (docs/releases/automation.md).
dpkg-query -W -f='release-libs: ${Package}:${Architecture} ${Version}\n' \
  libsqlite3-0:amd64 libsqlite3-dev:amd64 libsqlite3-0:arm64 libpq5:amd64 libpq-dev \
  libpq5:arm64 qemu-user

# A link whose target is not an AArch64 ELF file (e_machine 0xb7 at offset 18) is refused.
arm=/usr/lib/aarch64-linux-gnu
mkdir -p "$dir"
for pair in "libsqlite3.so:libsqlite3.so.0" "libpq.so:libpq.so.5"; do
  name=${pair%%:*}
  target="$arm/${pair#*:}"
  [ -f "$target" ] || fail "no $target after the install"
  [ "$(od -An -tx1 -j18 -N2 "$(readlink -f "$target")" | tr -d ' \n')" = b700 ] ||
    fail "$target is not an AArch64 library"
  ln -sfn "$target" "$dir/$name"
done
echo "$dir"
