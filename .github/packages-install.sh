#!/usr/bin/env bash
# The packages' install test (docs/releases/packaging.md, "The install test"): installs the Zigcube
# packages in clean Debian 12, Ubuntu 24.04, Fedora and Rocky Linux 9 containers the way a user
# would, from signed repositories by name, and checks what a user would see. Shell because it
# drives docker, apt and dnf (docs/STYLE.md: a `.sh` file needs a written reason; this is it).
#
#   .github/packages-install.sh [IMAGE...]        on the host; default: the four pinned images
#
# On the host it builds two trees from zig-out/release-bin (.github/build-release-bin.sh), 0.0.0 and
# 0.0.1, signed with the fixed test key and dated now (so apt checks a real Valid-Until), 0.0.1 with
# a changed server.zon, serves both over HTTP on 127.0.0.1 and runs this script with --inside in each
# container. zigbox-dev's `zigbox` comes from the real repositories at zigbox.org, checked with their
# own key: the test needs that network. Nothing the packages should pull in is installed first.
# PACKAGES_INSTALL_CA names a CA bundle to trust in the containers (a TLS-intercepting proxy);
# PACKAGES_INSTALL_PORT the HTTP port (default 18765).
set -euo pipefail

fail() { echo "packages-install: $*" >&2; exit 1; }
say() { echo "packages-install: $*"; }

images_default=(
  "debian:12@sha256:268fb24c39bca92d326dd83ea3abebe4a3f7751c804ffef23bb6d857dd343ff8"
  "ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5"
  "fedora:42@sha256:99e203b80b1c3d8f7e161ec10a68fd02b081ef83a3963553e513c82846b97814"
  "rockylinux:9@sha256:d7be1c094cc5845ee815d4632fe377514ee6ebcf8efaed6892889657e5ddaaa6"
)
packages=(zigcube zigcube-server-sqlite zigcube-agent zigbox-dev)

# ---- Inside a container ---------------------------------------------------------------------

inside_setup_deb() {
  export DEBIAN_FRONTEND=noninteractive
  echo 'Acquire::http::Proxy::127.0.0.1 "DIRECT";' > /etc/apt/apt.conf.d/99zigcube-local
  apt-get update -qq > /dev/null
  apt-get install -y -qq ca-certificates > /dev/null
  if [ -f /ca.crt ]; then cp /ca.crt /usr/local/share/ca-certificates/proxy.crt; fi
  update-ca-certificates > /dev/null 2>&1
  cat > /etc/apt/sources.list.d/zigcube.list << EOF
deb [signed-by=/keys/zigcube-test.gpg] $REPO/0.0.0/apt zigcube main
deb [signed-by=/keys/zigbox-archive-keyring.gpg] https://zigbox.org/apt stable main
EOF
  apt-get update -qq > /dev/null
  # Keep the administrator's conffile on upgrade without asking, as unattended upgrades do.
  apt_options=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  install() { apt-get install "${apt_options[@]}" "$@" > /dev/null; }
  upgrade() {
    sed -i "s|$REPO/0.0.0/|$REPO/0.0.1/|" /etc/apt/sources.list.d/zigcube.list
    apt-get update -qq > /dev/null
    apt-get upgrade "${apt_options[@]}" > /dev/null
  }
  swap() { install zigcube-server-postgres; }
  version_of() { dpkg-query -W -f='${Status} ${Version}' "$1" 2> /dev/null | sed -n 's/^install ok installed //p'; }
  files_of() { dpkg -L "$@"; }
  remove_all() { apt-get purge -y -qq "$@" > /dev/null; }
  new_conffile=/etc/zigcube/server.zon.dpkg-dist
  systemd_install() { apt-get install -y -qq systemd > /dev/null; }
}

inside_setup_rpm() {
  if [ -f /ca.crt ]; then cp /ca.crt /etc/pki/ca-trust/source/anchors/proxy.crt; update-ca-trust; fi
  export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost
  cat > /etc/yum.repos.d/zigcube.repo << EOF
[zigcube]
name=Zigcube (test key)
baseurl=$REPO/0.0.0/rpm/zigcube/\$basearch
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///keys/zigcube-test.asc

[zigbox]
name=Zigbox
baseurl=https://zigbox.org/rpm/\$basearch
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///keys/zigbox-archive-keyring.asc
EOF
  install() { dnf -y -q install "$@" > /dev/null; }
  upgrade() {
    sed -i "s|$REPO/0.0.0/|$REPO/0.0.1/|" /etc/yum.repos.d/zigcube.repo
    dnf -y -q upgrade --refresh zigcube zigcube-agent zigcube-server-sqlite zigbox-dev > /dev/null
  }
  # zigbox-dev needs the SQLite flavour, so a swap removes it, as apt does; unlike apt, dnf would
  # also remove what zigbox-dev pulled in (the agent) unless told to keep it.
  swap() {
    dnf -y -q swap --allowerasing --setopt=clean_requirements_on_remove=False \
      zigcube-server-sqlite zigcube-server-postgres > /dev/null
  }
  version_of() { if rpm -q --quiet "$1"; then rpm -q --qf '%{VERSION}' "$1"; fi; }
  files_of() { rpm -ql "$@"; }
  remove_all() { dnf -y -q remove "$@" > /dev/null; }
  new_conffile=/etc/zigcube/server.zon.rpmnew
  systemd_install() { dnf -y -q install systemd > /dev/null; }
}

# Each named package is installed at VERSION.
expect_versions() {
  local version=$1 name got
  shift
  for name in "$@"; do
    got=$(version_of "$name")
    [ "${got%%-*}" = "$version" ] || fail "$name is at '${got}', not $version"
  done
}

# GET /v1/status on 127.0.0.1:PORT answers 200 (no curl in the images: bash's /dev/tcp).
expect_status() {
  local reply
  exec 3<> "/dev/tcp/127.0.0.1/$1"
  printf 'GET /v1/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
  reply=$(head -1 <&3)
  exec 3>&-
  case $reply in "HTTP/1.1 200"*) ;; *) fail "GET /v1/status said: $reply" ;; esac
}

inside_run_server() {
  mkdir -p /tmp/zc
  # The shipped configuration, but the store in /tmp: /var/lib/zigcube is systemd's
  # StateDirectory, and nothing here may create it.
  zcube-server --config /etc/zigcube/server.zon --store sqlite:/tmp/zc/server.db \
    > /tmp/zc/server.log 2>&1 &
  local server=$! tries=0
  until (exec 3<> /dev/tcp/127.0.0.1/7070) 2> /dev/null; do
    kill -0 "$server" 2> /dev/null || { cat /tmp/zc/server.log >&2; fail "the server exited"; }
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || fail "the server did not listen on 127.0.0.1:7070"
    sleep 0.1
  done
  expect_status 7070
  kill "$server"
  wait "$server" 2> /dev/null || true
}

inside_check_install() {
  expect_versions 0.0.0 "${packages[@]}"
  [ -z "$(version_of zigcube-server-postgres)" ] || fail "zigcube-server-postgres was installed"
  say "zigbox $(version_of zigbox) from zigbox.org: $(command -v zbx || echo 'no zbx')"
  zcube version > /dev/null || fail "zcube version failed"
  local said
  said=$(zcube-server --version)
  [ "${said%% *}" = zcube-server ] || fail "zcube-server --version said: $said"
  zcube-agent --help > /dev/null || fail "zcube-agent --help failed"
  ldd /usr/bin/zcube-server > /tmp/ldd.txt || fail "ldd failed on zcube-server"
  if grep -q 'not found' /tmp/ldd.txt; then cat /tmp/ldd.txt >&2; fail "a library is missing"; fi
  say "zcube-server links: $(awk '{print $1}' /tmp/ldd.txt | tr '\n' ' ')"
  # Units ship disabled, nothing creates the state directories, and no package owns them (so a
  # remove cannot delete a store).
  if ls /etc/systemd/system/*.wants/zcube-* > /dev/null 2>&1; then fail "a unit was enabled"; fi
  [ ! -e /var/lib/zigcube ] || fail "/var/lib/zigcube exists after the install"
  [ ! -e /var/lib/zcube-agent ] || fail "/var/lib/zcube-agent exists after the install"
  if files_of "${packages[@]}" | grep -q '^/var/lib'; then fail "a package owns /var/lib"; fi
}

inside_upgrade() {
  echo '// edited by the administrator' >> /etc/zigcube/server.zon
  upgrade
  expect_versions 0.0.1 "${packages[@]}"
  grep -q 'edited by the administrator' /etc/zigcube/server.zon ||
    fail "the upgrade replaced the edited server.zon"
  [ -f "$new_conffile" ] || fail "the upgrade left no $new_conffile beside the edited file"
  grep -q 'version 0.0.1 of the install test' "$new_conffile" ||
    fail "$new_conffile is not 0.0.1's server.zon"
  say "upgrade 0.0.0 -> 0.0.1 kept the edited server.zon and wrote ${new_conffile##*/}"
}

inside_swap() {
  swap
  expect_versions 0.0.1 zigcube zigcube-server-postgres zigcube-agent
  [ -z "$(version_of zigcube-server-sqlite)" ] || fail "the sqlite flavour stayed after the swap"
  # zigbox-dev depends on the SQLite flavour: the swap removes it on both families.
  [ -z "$(version_of zigbox-dev)" ] || fail "zigbox-dev stayed after the swap"
  say "after the swap /etc/zigcube/server.zon says: $(grep -E '^ *\.store' /etc/zigcube/server.zon)"
  local refusal
  refusal=$(zcube-server --store sqlite:/tmp/zc/swap.db 2>&1 || true)
  grep -q 'ZC-E0217' <<< "$refusal" || fail "no ZC-E0217 from the postgres flavour: $refusal"
}

inside_verify_units() {
  local units
  units=$(files_of zigcube-server-postgres zigcube-agent | grep '\.service$')
  [ "$(wc -l <<< "$units")" = 2 ] || fail "expected two units, found: $units"
  systemd_install
  # shellcheck disable=SC2086 # two paths, no spaces
  systemd-analyze verify $units || fail "systemd-analyze verify refused a unit"
}

inside() {
  [ -n "${REPO:-}" ] || fail "--inside needs REPO"
  if command -v apt-get > /dev/null; then inside_setup_deb; else inside_setup_rpm; fi
  install zigbox-dev
  inside_check_install
  inside_run_server
  inside_upgrade
  inside_swap
  inside_verify_units
  remove_all zigcube-server-postgres zigcube-agent zigcube
  for file in /usr/bin/zcube /usr/bin/zcube-server /usr/bin/zcube-agent; do
    [ ! -e "$file" ] || fail "$file is still there after the remove"
  done
  [ ! -e /var/lib/zigcube ] || fail "/var/lib/zigcube exists after the remove"
  say "$(. /etc/os-release && echo "$PRETTY_NAME"): ok"
}

# ---- On the host ----------------------------------------------------------------------------

# The servers are the RHEL 9 build: no glibc symbol newer than Rocky Linux 9's 2.34.
host_check_glibc() {
  local file newest
  for file in zig-out/release-bin/zcube-server-*-"$(uname -m)"; do
    newest=$(objdump -T "$file" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)
    [ "$(printf '%s\nGLIBC_2.34\n' "$newest" | sort -V | tail -1)" = GLIBC_2.34 ] ||
      fail "$file needs $newest: build it with .github/build-release-bin.sh"
  done
}

host_build_trees() {
  local work=$1 now version assets
  now=$(date +%s)
  for version in 0.0.0 0.0.1; do
    assets=packaging
    if [ "$version" = 0.0.1 ]; then
      assets="$work/assets"
      rm -rf "$assets" && cp -r packaging "$assets"
      echo '// version 0.0.1 of the install test' >> "$assets/server-sqlite.zon"
      echo '// version 0.0.1 of the install test' >> "$assets/server-postgres.zon"
    fi
    rm -rf zig-out/packages
    zig build packages-check -Dtest-key=true -Dpackage-arch="$(uname -m)" \
      -Dpackage-version="$version" -Dpackage-assets="$assets" -Dsigned-at="$now"
    rm -rf "${work:?}/serve/$version" && cp -r zig-out/packages "$work/serve/$version"
  done
}

host() {
  local root work port images server status=0
  root=$(cd "$(dirname "$0")/.." && pwd)
  cd "$root"
  work="$root/zig-out/packages-install"
  port=${PACKAGES_INSTALL_PORT:-18765}
  images=("$@")
  [ "${#images[@]}" -gt 0 ] || images=("${images_default[@]}")
  mkdir -p "$work/serve" "$work/keys"
  host_check_glibc
  host_build_trees "$work"
  cp "$work/serve/0.0.0/zigbox-test-key.gpg" "$work/keys/zigcube-test.gpg"
  cp "$work/serve/0.0.0/zigbox-test-key.asc" "$work/keys/zigcube-test.asc"
  curl -fsSL -o "$work/keys/zigbox-archive-keyring.gpg" https://zigbox.org/zigbox-archive-keyring.gpg
  curl -fsSL -o "$work/keys/zigbox-archive-keyring.asc" https://zigbox.org/zigbox-archive-keyring.asc
  python3 -m http.server --bind 127.0.0.1 --directory "$work/serve" "$port" > "$work/http.log" 2>&1 &
  server=$!
  trap 'kill "${server:-}" 2> /dev/null || true' EXIT
  local mounts=(-v "$work/keys:/keys:ro" -v "$root/.github/packages-install.sh:/t.sh:ro")
  if [ -n "${PACKAGES_INSTALL_CA:-}" ]; then mounts+=(-v "$PACKAGES_INSTALL_CA:/ca.crt:ro"); fi
  local image
  for image in "${images[@]}"; do
    say "--- $image"
    docker run --rm --network host "${mounts[@]}" -e "REPO=http://127.0.0.1:$port" \
      -e HTTP_PROXY -e HTTPS_PROXY -e http_proxy -e https_proxy \
      -e no_proxy=127.0.0.1,localhost -e NO_PROXY=127.0.0.1,localhost \
      "$image" bash ${PACKAGES_INSTALL_TRACE:+-x} /t.sh --inside || { say "FAILED in $image"; status=1; }
  done
  return "$status"
}

if [ "${1:-}" = --inside ]; then inside; else host "$@"; fi
