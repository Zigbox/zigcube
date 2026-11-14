#!/usr/bin/env bash
# Runs .github/release-sign.sh with a throwaway key shaped like the release key: a certify-only
# RSA 4096 primary, one RSA 4096 signing subkey, a passphrase, and the secret export of the
# subkey alone (primary stubbed). Nothing is attached or dispatched; the key vouches for nothing.
# The fixed `-Dtest-key` of `zig build packages` is an Ed25519 key held inside the package
# tool and cannot be imported by gpg, so it cannot exercise the import and subkey checks.
# Needs ZCUBE_BIN_DIR and ZCUBE_ZIGBOX_VERSION as release-sign.sh does.
# Usage: .github/release-sign-test.sh OUTPUT_DIR
set -euo pipefail

output=${1:?usage: release-sign-test.sh OUTPUT_DIR}
home=$(mktemp -d)
trap 'GNUPGHOME=$home gpgconf --kill gpg-agent 2>/dev/null || true; rm -rf "$home"' EXIT

passphrase=test-only-passphrase
gpg_home() { GNUPGHOME=$home gpg --batch --no-tty --pinentry-mode loopback \
  --passphrase "$passphrase" "$@" 2> /dev/null; }

gpg_home --quick-generate-key "Zigbox release test <test@invalid>" rsa4096 cert 1d
primary=$(GNUPGHOME=$home gpg --batch --list-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }')
# The public key as checked in before the subkey exists: the script must refuse it.
GNUPGHOME=$home gpg --batch --export -a "$primary" > "$home/public-without-subkey.asc"
gpg_home --quick-add-key "$primary" rsa4096 sign 1d
subkey=$(GNUPGHOME=$home gpg --batch --list-keys --with-colons |
  awk -F: '$1 == "sub" { s = 1; next } $1 == "fpr" && s { print $10; exit }')
GNUPGHOME=$home gpg --batch --export -a "$primary" > "$home/public.asc"

ZIGBOX_SIGNING_PASSPHRASE=$passphrase
ZIGBOX_SIGNING_FPR=$primary
ZCUBE_PUBLIC_KEY=$home/public.asc
export ZIGBOX_SIGNING_KEY ZIGBOX_SIGNING_PASSPHRASE ZIGBOX_SIGNING_FPR ZCUBE_PUBLIC_KEY

refused() { # refused OUTPUT REASON: the script must fail and say REASON
  local refusal
  if refusal=$("$(dirname "$0")/release-sign.sh" "$1" 2>&1); then
    echo "release-sign-test: accepted a bad input ($2)" >&2
    exit 1
  fi
  grep -q "$2" <<< "$refusal" || {
    echo "release-sign-test: wrong refusal for '$2': $refusal" >&2
    exit 1
  }
}

# An export that still holds the secret primary key must be refused, with the reason.
ZIGBOX_SIGNING_KEY=$(gpg_home --armor --export-secret-keys "$primary")
refused "$output/refused" 'holds the secret primary key'

ZIGBOX_SIGNING_KEY=$(gpg_home --armor --export-secret-subkeys "${subkey}!")
# A checked-in public key without the signing subkey must be refused.
ZCUBE_PUBLIC_KEY=$home/public-without-subkey.asc refused "$output/refused" 'does not hold the signing subkey'
# A fingerprint that is not the key's primary must be refused.
ZIGBOX_SIGNING_FPR=09991DC39816D3C914E2A22C5AB00BC328B7DBB7 refused "$output/refused" 'not by the primary key'

# The same file the release runs.
"$(dirname "$0")/release-sign.sh" "$output"
