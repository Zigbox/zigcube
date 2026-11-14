#!/usr/bin/env bash
# Builds the four executables `zig build packages` reads, for the machine's own architecture, into
# zig-out/release-bin (docs/releases/packaging.md, "Building the executables"):
#   zcube-<arch>, zcube-agent-<arch>              static, built here
#   zcube-server-sqlite-<arch>, -postgres-<arch>  dynamic, built in a RHEL 9 compatible container
# The server links glibc, libsqlite3 and libpq, so it is built on the oldest supported baseline
# (Rocky Linux 9: glibc 2.34, libpq 13, SQLite 3.34) and runs on Debian 12, Ubuntu 24.04, Fedora
# and RHEL 9; a server built on this runner would need its newer glibc (docs/briefs/packaging.md).
# Shell because it drives docker (docs/STYLE.md: a `.sh` file needs a written reason; this is it).
# Needs zig on PATH (the pinned version), docker, and zig-pkg/ holding the pinned Zigbox package.
# The server's build in the container does not fetch: it reads zig-pkg/ through the mount.
set -euo pipefail

# Pinned by digest like CI's Postgres image (resolved from Docker Hub on 2026-11-14).
image="rockylinux:9@sha256:d7be1c094cc5845ee815d4632fe377514ee6ebcf8efaed6892889657e5ddaaa6"
root=$(cd "$(dirname "$0")/.." && pwd)
arch=$(uname -m)
out="$root/zig-out/release-bin"
zig=$(command -v zig) || { echo "build-release-bin: zig is not on PATH" >&2; exit 1; }
zig_dir=$(dirname "$(readlink -f "$zig")")
mkdir -p "$out"

cd "$root"
zig build -Doptimize=ReleaseSafe -Dstore=sqlite --prefix zig-out/release-host
cp zig-out/release-host/bin/zcube "$out/zcube-$arch"
cp zig-out/release-host/bin/zcube-agent "$out/zcube-agent-$arch"

# The caches stay inside the container: its libraries are not the host's.
docker run --rm --network host -v "$root:/src" -v "$zig_dir:/zig:ro" -w /src \
  -e HTTP_PROXY -e HTTPS_PROXY -e http_proxy -e https_proxy -e "HOST_UID=$(id -u)" \
  -e "ARCH=$arch" "$image" bash -euo pipefail -c '
    dnf -y -q install sqlite-devel libpq-devel > /dev/null
    export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-global
    for store in sqlite postgres; do
      /zig/zig build -Doptimize=ReleaseSafe -Dstore="$store" --cache-dir /tmp/zig-cache \
        --prefix "/tmp/out-$store"
      cp "/tmp/out-$store/bin/zcube-server" "zig-out/release-bin/zcube-server-$store-$ARCH"
      chown "$HOST_UID" "zig-out/release-bin/zcube-server-$store-$ARCH"
    done
    ldd --version | head -1'
ls -l "$out"
