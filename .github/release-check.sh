#!/usr/bin/env bash
# Checks a directory of Zigcube release assets before anyone can download them: exactly
# SHA256SUMS and one tarball for each of x86_64-linux and aarch64-linux, the sums match, each
# tarball holds exactly COMMIT, LICENSE and bin/{zcube,zcube-server,zcube-agent} under
# zigcube-<version>-<platform>/, COMMIT names the release commit, every binary is an ELF file
# for its platform and prints <name> <version>. The x86_64 binaries run on the host, the aarch64
# ones under qemu-aarch64 (release-libs.sh installs it and the arm64 libraries they load).
#
# Usage: release-check.sh DIR VERSION COMMIT. Used by release.yml's `build` job (on the build's
# output, before it is attached to the draft) and by ci.yml's `release` job
# (docs/releases/automation.md). Reads nothing secret.
set -euo pipefail

fail() { echo "release-check: $1" >&2; exit 1; }

dir=${1:-}
version=${2:-}
commit=${3:-}
if [ -z "$dir" ] || [ -z "$version" ] || [ -z "$commit" ]; then
  fail "usage: release-check.sh DIR VERSION COMMIT"
fi
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "'$commit' is not a full commit id"
platforms=(x86_64-linux aarch64-linux)
bins=(zcube zcube-server zcube-agent)

expected=$({
  echo SHA256SUMS
  for p in "${platforms[@]}"; do echo "zigcube-$version-$p.tar.gz"; done
} | sort)
actual=$(cd "$dir" && find . -mindepth 1 -maxdepth 1 -printf '%P\n' | sort)
[ "$actual" = "$expected" ] ||
  fail "$dir holds:"$'\n'"$actual"$'\n'"and should hold exactly:"$'\n'"$expected"
[ "$(cut -d' ' -f3 "$dir/SHA256SUMS" | sort)" = "$(grep -v '^SHA256SUMS$' <<< "$expected")" ] ||
  fail "SHA256SUMS does not name exactly the two tarballs"
(cd "$dir" && sha256sum --strict --quiet -c SHA256SUMS) || fail "SHA256SUMS does not match"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Prints the name, then the version, that one binary reports, as one line.
version_of() {
  local runner=() exe=$2
  if [ "$1" = aarch64-linux ]; then runner=(qemu-aarch64 -L /); fi
  case "$(basename "$exe")" in
    zcube) "${runner[@]}" "$exe" version ;;
    *) "${runner[@]}" "$exe" --version ;;
  esac
}

for p in "${platforms[@]}"; do
  top="zigcube-$version-$p"
  tarball="$dir/$top.tar.gz"
  want=$(printf '%s\n' "$top" "$top/COMMIT" "$top/LICENSE" "${bins[@]/#/$top/bin/}" | sort)
  got=$(tar -tzf "$tarball" | sort)
  [ "$got" = "$want" ] || fail "$top.tar.gz holds:"$'\n'"$got"$'\n'"and should hold:"$'\n'"$want"
  tar -xzf "$tarball" -C "$work"
  [ "$(cat "$work/$top/COMMIT")" = "$commit" ] ||
    fail "$top/COMMIT is '$(head -c 80 "$work/$top/COMMIT")', not $commit"
  case "$p" in
    x86_64-linux) machine="Advanced Micro Devices X86-64" ;;
    aarch64-linux) machine="AArch64" ;;
  esac
  for b in "${bins[@]}"; do
    exe="$work/$top/bin/$b"
    [ -x "$exe" ] || fail "$top/bin/$b is not executable"
    got_machine=$(readelf -h "$exe" | sed -n 's/^ *Machine: *//p')
    [ "$got_machine" = "$machine" ] || fail "$top/bin/$b is for '$got_machine', not $machine"
    said=$(version_of "$p" "$exe" 2>&1) || fail "$top/bin/$b failed to print its version: $said"
    [ "$said" = "$b $version" ] || fail "$top/bin/$b says '$said', not '$b $version'"
  done
  echo "release-check: $top.tar.gz: ${bins[*]} $version at $commit"
done
echo "release-check: PASS $version ($(wc -l < "$dir/SHA256SUMS") tarballs, SHA256SUMS matches)"
