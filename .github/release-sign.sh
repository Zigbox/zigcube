#!/usr/bin/env bash
# Signs the Zigcube packages and writes zigcube-repos.tar.gz. Shell, not Zig, because the program
# that signs is gpg (docs/STYLE.md: a `.sh` file needs a written reason; this is it) and this is
# only the glue between `zig build packages` and gpg. Ported from Zigbox's release-sign.sh. Both
# the release workflow and its test job run this file, so the tested code is the released code.
# Usage: .github/release-sign.sh OUTPUT_DIR
#
# Environment (secrets are never printed and never passed as an argument):
#   ZIGBOX_SIGNING_KEY         ASCII-armored secret subkey export (primary stubbed)
#   ZIGBOX_SIGNING_PASSPHRASE  the subkey's passphrase
#   ZIGBOX_SIGNING_FPR         fingerprint of the primary key; every signature must be by one of
#                              its subkeys, or the script fails
#   ZCUBE_BIN_DIR              the built executables (`zig build packages -Dbin`)
#   ZCUBE_ZIGBOX_VERSION       the oldest zigbox package zigbox-dev accepts
#   ZCUBE_PUBLIC_KEY           the checked-in public key (default docs/releases/zigbox-release-key.asc);
#                              the signing subkey must be in it, or the script fails
# Output: OUTPUT_DIR/zigcube-repos.tar.gz. It holds apt/dists/zigcube, apt/pool and rpm/zigcube
# and nothing else: no keyring (users fetch it from zigbox.org), no dot file, no .html.
# Run from the repository root. Needs zig, gpg, rpm. See docs/releases/packaging.md.
set -euo pipefail
# No `set -x`: this script handles the key.

output=${1:?usage: release-sign.sh OUTPUT_DIR}
: "${ZIGBOX_SIGNING_KEY:?ZIGBOX_SIGNING_KEY is not set}"
: "${ZIGBOX_SIGNING_PASSPHRASE:?ZIGBOX_SIGNING_PASSPHRASE is not set}"
: "${ZIGBOX_SIGNING_FPR:?ZIGBOX_SIGNING_FPR is not set}"
: "${ZCUBE_BIN_DIR:?ZCUBE_BIN_DIR is not set}"
: "${ZCUBE_ZIGBOX_VERSION:?ZCUBE_ZIGBOX_VERSION is not set}"
public_key=${ZCUBE_PUBLIC_KEY:-docs/releases/zigbox-release-key.asc}
case "$ZIGBOX_SIGNING_FPR" in
  *[!0-9A-Fa-f]* | "") echo "release-sign: ZIGBOX_SIGNING_FPR is not a hex fingerprint" >&2; exit 1 ;;
esac
primary=${ZIGBOX_SIGNING_FPR^^}
[ "${#primary}" -eq 40 ] || { echo "release-sign: ZIGBOX_SIGNING_FPR is not 40 hex digits" >&2; exit 1; }

fail() { echo "release-sign: $*" >&2; exit 1; }
[ -s "$public_key" ] || fail "the public key $public_key is missing"

work=$(mktemp -d)
signing_home=$work/gnupg-sign
verify_home=$work/gnupg-verify
signatures=$work/signatures
mkdir -m 0700 "$signing_home" "$verify_home" "$signatures"
packages=zig-out/packages
rpm_count=10 # five packages for each of two architectures

# Remove every trace of the key, also when a step fails. The agent holds the key in memory.
cleanup() {
  local status=$?
  for home in "$signing_home" "$verify_home"; do
    GNUPGHOME=$home gpgconf --kill gpg-agent 2>/dev/null || true
  done
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

gpg_sign() { GNUPGHOME=$signing_home gpg --batch --no-tty --pinentry-mode loopback \
  --passphrase-file "$signing_home/passphrase" "$@"; }

# The passphrase goes in a 0600 file in the throwaway home; the key comes in on stdin.
(umask 077 && printf '%s' "$ZIGBOX_SIGNING_PASSPHRASE" > "$signing_home/passphrase")
printf '%s\n' "$ZIGBOX_SIGNING_KEY" | gpg_sign --import 2> "$work/import.log" ||
  { echo "release-sign: gpg could not import ZIGBOX_SIGNING_KEY" >&2; exit 1; }
# Only gpg needed these, once. Unset them so that zig, rpm and tar do not inherit them.
unset ZIGBOX_SIGNING_KEY ZIGBOX_SIGNING_PASSPHRASE

# The one signing subkey, which must belong to the primary key named by ZIGBOX_SIGNING_FPR.
# A colon listing: `sec` opens the key (field 15 is `#` when the primary secret is a stub), then
# `fpr` is its fingerprint; `ssb` opens a subkey (field 2 validity, field 3 bits, field 4
# algorithm, field 12 capabilities), then its `fpr`. The policy is RSA 4096 (algorithm 1) for
# both, as published.
listing=$(GNUPGHOME=$signing_home gpg --batch --list-secret-keys --with-colons 2>/dev/null)
subkey=$(awk -F: -v primary="$primary" '
  $1 == "sec" { section = "sec"; if ($3 != 4096 || $4 != 1) weak = 1; if ($15 != "#") plain = 1; next }
  $1 == "ssb" { section = ($2 == "e" || $2 == "r") ? "bad" : (index($12, "s") ? "sign" : "other")
                if (section == "sign" && ($3 != 4096 || $4 != 1)) weak = 1; next }
  $1 == "fpr" && section == "sec" { top = $10; section = ""; next }
  $1 == "fpr" && section == "sign" { print $10; section = "" }
  END { if (top != primary) print "WRONG-PRIMARY"; if (weak) print "WEAK"; if (plain) print "PRIMARY-SECRET" }
' <<< "$listing")
case "$subkey" in
  *WRONG-PRIMARY*) fail "the imported key is not by the primary key ZIGBOX_SIGNING_FPR" ;;
  *PRIMARY-SECRET*) fail "the imported key holds the secret primary key; export the subkey alone with --export-secret-subkeys (docs/releases/packaging.md)" ;;
  *WEAK*) fail "the primary and the signing subkey must be RSA 4096 (docs/releases/packaging.md)" ;;
  "") fail "the imported key has no usable (unexpired, unrevoked) signing subkey" ;;
esac
[ "$(wc -l <<< "$subkey")" -eq 1 ] || fail "the imported key has more than one signing subkey"
subkey=${subkey^^}
echo "release-sign: signing subkey ${subkey: -16} of primary ${primary: -16}"

# The checked-in public key is what verifies the signatures and what rpm imports. It must be the
# primary named by ZIGBOX_SIGNING_FPR and must already hold the signing subkey: after the yearly
# subkey renewal the owner checks in the new public key first (docs/releases/packaging.md).
GNUPGHOME=$verify_home gpg --batch --import "$public_key" 2> /dev/null ||
  fail "gpg could not import $public_key"
published=$(GNUPGHOME=$verify_home gpg --batch --list-keys --with-colons 2> /dev/null |
  awk -F: '$1 == "fpr" { print toupper($10) }')
grep -qx "$primary" <<< "$published" || fail "$public_key is not the key $primary"
grep -qx "$subkey" <<< "$published" ||
  fail "$public_key does not hold the signing subkey ${subkey: -16}; check in the renewed public key"

sign_with() { gpg_sign -u "${subkey}!" "$@"; }
build() { zig build "$@" -Dbin="$ZCUBE_BIN_DIR" -Dzigbox-version="$ZCUBE_ZIGBOX_VERSION"; }

# Round 1: each rpm's header, a binary detached signature named <rpm>.header.sig.
rm -rf "$packages"
build packages
headers=("$packages"/to-sign/*.header)
[ "${#headers[@]}" -eq "$rpm_count" ] || fail "expected $rpm_count rpm headers to sign, found ${#headers[@]}"
for header in "${headers[@]}"; do
  sign_with --detach-sign -o "$signatures/${header##*/}.sig" "$header"
done

# Round 2: embed the header signatures, then sign the repository metadata.
build packages -Dsignatures="$signatures"
release=$packages/apt/dists/zigcube/Release
sign_with --clearsign -o "$signatures/InRelease" "$release"
sign_with -abs -o "$signatures/Release.gpg" "$release"
for architecture in x86_64 aarch64; do
  sign_with -abs -o "$signatures/repomd.$architecture.xml.asc" \
    "$packages/rpm/zigcube/$architecture/repodata/repomd.xml"
done

# Final run places the signatures; the check reads the whole tree back.
build packages -Dsignatures="$signatures"
build packages-check -Dsignatures="$signatures"

# Verify every signature against the checked-in public key alone, in a home with no secret key.
verify_gpg() { GNUPGHOME=$verify_home gpg --batch --no-tty --status-fd 1 "$@" 2> /dev/null; }
# GOODSIG, then VALIDSIG <signing fpr> ... <primary fpr> (the last field): by a subkey of the
# primary and not by the primary itself.
check_gpg() {
  local status
  status=$(verify_gpg --verify "$@") || fail "gpg --verify refused $*"
  grep -q '^\[GNUPG:\] GOODSIG ' <<< "$status" || fail "no good signature on $*"
  local fields
  fields=$(awk '$2 == "VALIDSIG" { print $3, $NF }' <<< "$status")
  [ -n "$fields" ] || fail "no valid signature on $*"
  [ "${fields#* }" = "$primary" ] || fail "$* is not by a subkey of ZIGBOX_SIGNING_FPR"
  [ "${fields% *}" != "$primary" ] || fail "$* is signed by the primary key, not a subkey"
  [ "${fields% *}" = "$subkey" ] || fail "$* is not by the signing subkey"
}
check_gpg "$packages/apt/dists/zigcube/Release.gpg" "$release"
check_gpg "$packages/apt/dists/zigcube/InRelease"
for architecture in x86_64 aarch64; do
  check_gpg "$packages/rpm/zigcube/$architecture/repodata/repomd.xml.asc" \
    "$packages/rpm/zigcube/$architecture/repodata/repomd.xml"
done

# rpm: import the same public key into a throwaway rpm database, check every rpm's header.
rpmdb=$work/rpmdb
mkdir -m 0700 "$rpmdb"
rpmkeys --dbpath "$rpmdb" --import "$public_key"
rpms=("$packages"/rpm/zigcube/*/*.rpm)
[ "${#rpms[@]}" -eq "$rpm_count" ] || fail "expected $rpm_count rpms, found ${#rpms[@]}"
for rpm_file in "${rpms[@]}"; do
  report=$(rpm --dbpath "$rpmdb" -Kv "$rpm_file") || fail "rpm -Kv refused $rpm_file"
  if grep -Eiq 'NOT OK|BAD|MISSING|NOKEY' <<< "$report"; then
    fail "rpm -Kv found a bad signature on $rpm_file"
  fi
  key_id=${subkey: -8}
  grep -Eiq "Signature, key ID ${key_id}: OK" <<< "$report" ||
    fail "$rpm_file has no header signature by the signing subkey"
done

# The asset: only Zigcube's own paths. zigbox.org's deploy refuses anything else.
mkdir -p "$output"
tar -czf "$output/zigcube-repos.tar.gz" -C "$packages" apt rpm
stray=$(tar -tzf "$output/zigcube-repos.tar.gz" |
  grep -Ev '^(apt|rpm)/$|^apt/(dists/zigcube|pool/main/z/(zigcube[^/]*|zigbox-dev))(/|$)|^apt/(dists|pool|pool/main|pool/main/z)/$|^rpm/zigcube(/|$)' || true)
[ -z "$stray" ] || fail "the asset holds a path outside Zigcube's own: $(head -n1 <<< "$stray")"
echo "release-sign: every signature verified; wrote $output/zigcube-repos.tar.gz"
