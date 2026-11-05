#!/bin/sh
# Generates the foreign-anchor fixtures of x509_foreign_test.zig with OpenSSL (3.0 or later).
# The tests read the committed files; nothing runs OpenSSL at test time. Rerun this only to
# change a fixture, then commit every file it writes (new keys, serials and dates each run).
#
#   anchor.pub              the anchor's Ed25519 public key, 32 raw bytes
#   other.pub               an unrelated Ed25519 public key, for the wrong-anchor row
#   minimal.der             a server leaf with only what the foreign profile needs (OpenSSL 3
#                           adds the two key identifiers unless told not to)
#   defaults.der            a server leaf as `openssl x509 -req` writes it with the usual extras
#   client.der              EKU clientAuth only
#   ca_true.der             BasicConstraints cA TRUE
#   unknown_critical.der    an unknown extension marked critical
#   two_unknown.der         two unknown non-critical extensions, 1.2.3.4 and 1.2.3.5 (the test
#                           renames the second to the first to make a duplicate)
#   serial21.der            a 21-byte serial
set -eu
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

openssl genpkey -algorithm ed25519 -out "$work/anchor.key"
openssl req -new -x509 -key "$work/anchor.key" -subj "/O=Fixture Corp/CN=Fixture Root" \
    -days 3650 -out "$work/anchor.pem"
openssl pkey -in "$work/anchor.key" -pubout -outform DER | tail -c 32 > anchor.pub
openssl genpkey -algorithm ed25519 -out "$work/other.key"
openssl pkey -in "$work/other.key" -pubout -outform DER | tail -c 32 > other.pub

openssl genpkey -algorithm ed25519 -out "$work/leaf.key"

# leaf NAME SUBJECT SERIAL EXTENSIONS...: one leaf signed by the anchor, 30 days.
leaf() {
    name=$1 subject=$2 serial=$3
    shift 3
    printf '%s\n' "$@" > "$work/$name.ext"
    openssl req -new -key "$work/leaf.key" -subj "$subject" -out "$work/$name.csr"
    openssl x509 -req -in "$work/$name.csr" -CA "$work/anchor.pem" -CAkey "$work/anchor.key" \
        -set_serial "$serial" -days 30 -extfile "$work/$name.ext" -outform DER -out "$name.der"
}

base_san="subjectAltName=DNS:broker.botpike.com"
base_ku="keyUsage=critical,digitalSignature"
base_eku="extendedKeyUsage=serverAuth"

leaf minimal "/CN=broker.botpike.com" 1 "$base_ku" "$base_eku" "$base_san" \
    "subjectKeyIdentifier=none" "authorityKeyIdentifier=none"
leaf defaults "/C=GB/ST=England/L=London/O=Botpike Ltd/OU=Brokers/CN=broker.botpike.com" \
    0x5a0f3c2e9b8d7a6f5e4d3c2b1a09f8e7d6c5b4a3 \
    "basicConstraints=critical,CA:FALSE" \
    "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth,clientAuth" \
    "subjectKeyIdentifier=hash" \
    "authorityKeyIdentifier=keyid:always" \
    "$base_san"
leaf client "/CN=broker.botpike.com" 2 "$base_ku" "extendedKeyUsage=clientAuth" "$base_san"
leaf ca_true "/CN=broker.botpike.com" 3 "basicConstraints=critical,CA:TRUE" \
    "$base_ku" "$base_eku" "$base_san"
leaf unknown_critical "/CN=broker.botpike.com" 4 "$base_ku" "$base_eku" "$base_san" \
    "1.2.3.4=critical,ASN1:NULL"
leaf two_unknown "/CN=broker.botpike.com" 5 "$base_ku" "$base_eku" "$base_san" \
    "1.2.3.4=ASN1:NULL" "1.2.3.5=ASN1:NULL"
leaf serial21 "/CN=broker.botpike.com" 0x0102030405060708090a0b0c0d0e0f101112131415 \
    "$base_ku" "$base_eku" "$base_san"
