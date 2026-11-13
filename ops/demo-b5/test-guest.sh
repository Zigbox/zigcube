#!/bin/sh
# Tests guest.sh (run by `zig build test`) against fake state directories and a fake zbx: the host
# half parses what it prints, so `containers` must read the layout `--runtime zigbox` writes
# (<state>/zigbox/<name>/) and fail without it, `export` must print each envelope as one `line `
# line, `key-new` the public key, and `policy` a policy that names it.
set -u
here=$(dirname "$0")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0
check() { # description, condition result (0 = holds)
    if [ "$2" -ne 0 ]; then echo "FAIL: $1"; failures=$((failures + 1)); fi
}

# A fake zbx: `key new NAME` writes a public key where zbx does, `trust export` prints two lines.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/zbx" <<'ZBX'
#!/bin/sh
case "$1 $2" in
    "key new") mkdir -p "$XDG_CONFIG_HOME/zbx/keys"
        printf 'zbx-ed25519:%064d\n# a comment\n' 7 >"$XDG_CONFIG_HOME/zbx/keys/$3.pub" ;;
    "trust export") printf '{"payloadType":"a"}\n\n{"payloadType":"b"}\n' ;;
    *) exit 3 ;;
esac
ZBX
chmod +x "$tmp/bin/zbx"
guest() {
    state=$1
    shift
    BIN="$tmp/bin" SIGNER="$tmp/signer" STATE="$state" sh "$here/guest.sh" "$@"
}

guest "$tmp/none" containers >"$tmp/out" 2>&1
check "containers without <state>/zigbox fails" $((! $? ))
mkdir -p "$tmp/real/zigbox/signed-job" "$tmp/real/containers/unsigned-job"
guest "$tmp/real" containers >"$tmp/out" 2>&1
check "containers in the real layout passes" $?
grep -qx "container signed-job" "$tmp/out"
check "a container under zigbox/ is listed" $?
grep -q "unsigned-job" "$tmp/out"
check "a directory elsewhere is not listed" $((! $? ))

guest "$tmp/real" key-new release >"$tmp/out" 2>&1
check "key-new passes" $?
grep -qx "public zbx-ed25519:0000000000000000000000000000000000000000000000000000000000000007" \
    "$tmp/out"
check "key-new prints the public key" $?

guest "$tmp/real" export b3:tree >"$tmp/out" 2>&1
check "export passes" $?
[ "$(grep -c '^line {"payloadType":"[ab]"}$' "$tmp/out")" -eq 2 ]
check "export prints each envelope as one line, blank lines skipped" $?

POLICY="$tmp/trust.zon" guest "$tmp/real" policy zbx-ed25519:abc >"$tmp/out" 2>&1
check "policy passes" $?
grep -q '.public = "zbx-ed25519:abc"' "$tmp/trust.zon" && grep -q 'require_signature = true' \
    "$tmp/trust.zon"
check "the policy names the key and requires a signature" $?

[ "$failures" -eq 0 ] && echo "test-guest: ok"
exit "$failures"
