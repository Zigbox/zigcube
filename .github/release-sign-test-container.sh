#!/usr/bin/env bash
# Runs .github/release-sign-test.sh in a Fedora container, which has the rpm and gpg the signing
# path needs (the runner's Ubuntu has no rpmkeys). Shell because it drives docker (docs/STYLE.md:
# a `.sh` file needs a written reason; this is it). Uses the throwaway key release-sign-test.sh
# generates; no secret is involved. A release signs both architectures, but the runner builds only
# its own (build-release-bin.sh): the other architecture gets a stand-in, a minimal static Zig
# executable built for it, under the four names. The packages only carry the files and this checks
# the signing, not the executables; the stand-in is a real ELF file of that machine, so the package
# tool's ELF check holds (an x86_64 file under an aarch64 name is refused). Run from anywhere;
# needs zig on PATH and docker.
set -euo pipefail

image="fedora:42@sha256:99e203b80b1c3d8f7e161ec10a68fd02b081ef83a3963553e513c82846b97814"
root=$(cd "$(dirname "$0")/.." && pwd)
zig_dir=$(dirname "$(readlink -f "$(command -v zig)")")
own=$(uname -m)
case "$own" in
  x86_64) other=aarch64 ;;
  aarch64) other=x86_64 ;;
  *) echo "release-sign-test-container: no packages for $own" >&2; exit 1 ;;
esac
bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
printf 'pub fn main() void {}\n' > "$bin/stand_in.zig"
zig build-exe -target "$other-linux" -O ReleaseSmall --cache-dir "$bin/cache" \
  --global-cache-dir "$bin/global" -femit-bin="$bin/stand-in" "$bin/stand_in.zig"
for stem in zcube zcube-agent zcube-server-sqlite zcube-server-postgres; do
  cp "$root/zig-out/release-bin/$stem-$own" "$bin/$stem-$own" ||
    { echo "release-sign-test-container: zig-out/release-bin lacks $stem-$own" >&2; exit 1; }
  cp "$bin/stand-in" "$bin/$stem-$other"
done
rm -rf "$bin/stand_in.zig" "$bin/stand-in" "$bin/cache" "$bin/global"
zigbox_version=$(grep -o 'refs/tags/v[0-9.]*\.tar\.gz' "$root/build.zig.zon" | sed 's|refs/tags/v||; s|\.tar\.gz||')

# Its own caches: the container's zig must not write the host's .zig-cache.
docker run --rm --network host -v "$root:/src" -v "$zig_dir:/zig:ro" -v "$bin:/bin-dir:ro" -w /src \
  -e HTTP_PROXY -e HTTPS_PROXY -e http_proxy -e https_proxy -e "HOST_UID=$(id -u)" \
  -e ZCUBE_BIN_DIR=/bin-dir -e "ZCUBE_ZIGBOX_VERSION=$zigbox_version" "$image" \
  bash -euo pipefail -c '
    dnf -y -q install gnupg2 rpm-sign > /dev/null
    export PATH=/zig:$PATH ZIG_GLOBAL_CACHE_DIR=/tmp/zig-global ZIG_LOCAL_CACHE_DIR=/tmp/zig-cache
    status=0
    .github/release-sign-test.sh /tmp/release-sign-out || status=$?
    chown -R "$HOST_UID" zig-out/packages 2> /dev/null || true
    exit "$status"'
