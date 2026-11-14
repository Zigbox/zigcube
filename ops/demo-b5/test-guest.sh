#!/bin/sh
# Tests guest.sh (run by `zig build test`) against fake state directories and a fake zbx: the host
# half parses what it prints, so `containers` must read the layout `--runtime zigbox` writes
# (<state>/zigbox/<name>/) and fail without it, `export` must print each envelope as one `line `
# line, `key-new` the public key, `policy` a policy that names it (also as the node's Zigbox
# policy), and `kept` must fail unless the node's store holds the lines and the log is clean.
set -u
here=$(dirname "$0")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0
check() { # description, condition result (0 = holds)
    if [ "$2" -ne 0 ]; then echo "FAIL: $1"; failures=$((failures + 1)); fi
}

# A fake zbx that prints what the real one printed. testdata/ was captured on 2026-11-13 from zbx
# 0.5.0 (the commit build.zig.zon pins, built from zig-pkg/) in a scratch XDG directory:
# `zbx key new release --no-passphrase` wrote release.pub; `zbx store import` of a small directory
# made a tree; `zbx sign <tree> --key release`, then `--key stranger`, and `zbx trust export <tree>`
# printed trust-export.txt (two DSSE envelopes, one per line); the same export from a store that
# had no signature for the tree exited 1 with trust-export-none.err. The fake's `trust export`
# prints `$EXPORT` (the signer's or the node's store), or exits 1 as zbx does when it is empty.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/zbx" <<ZBX
#!/bin/sh
case "\$1 \$2" in
    "key new") mkdir -p "\$XDG_CONFIG_HOME/zbx/keys"
        cp "$here/testdata/release.pub" "\$XDG_CONFIG_HOME/zbx/keys/\$3.pub" ;;
    "trust export") [ -s "\$EXPORT" ] || { cat "$here/testdata/trust-export-none.err" >&2; exit 1; }
        cat "\$EXPORT" ;;
    *) exit 3 ;;
esac
ZBX
chmod +x "$tmp/bin/zbx"
public=$(head -1 "$here/testdata/release.pub")
guest() {
    state=$1
    shift
    BIN="$tmp/bin" SIGNER="$tmp/signer" STATE="$state" NODE_POLICY="$tmp/node/zbx/policy.zon" \
        sh "$here/guest.sh" "$@"
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
grep -qx "public $public" "$tmp/out"
check "key-new prints the public key" $?

EXPORT="$here/testdata/trust-export.txt" guest "$tmp/real" export b3:tree >"$tmp/out" 2>&1
check "export passes" $?
[ "$(grep -c '^line {"payloadType":"application/vnd.in-toto+json",' "$tmp/out")" -eq 2 ]
check "export prints each envelope as one line" $?
# The same two lines with a blank line between and no newline after the last.
{ head -1 "$here/testdata/trust-export.txt"; echo; tail -1 "$here/testdata/trust-export.txt" |
    tr -d '\n'; } >"$tmp/ragged.txt"
EXPORT="$tmp/ragged.txt" guest "$tmp/real" export b3:tree >"$tmp/out" 2>&1
[ "$(grep -c '^line {"payloadType"' "$tmp/out")" -eq 2 ]
check "export skips blank lines and keeps a last line without a newline" $?

POLICY="$tmp/trust.zon" guest "$tmp/real" policy "$public" >"$tmp/out" 2>&1
check "policy passes" $?
grep -q ".public = \"$public\"" "$tmp/trust.zon" && grep -q 'require_signature = true' \
    "$tmp/trust.zon"
check "the policy names the key and requires a signature" $?
cmp -s "$tmp/trust.zon" "$tmp/node/zbx/policy.zon"
check "the node's Zigbox policy is the same policy" $?

# kept: the node's store holds the lines and the log has no "not kept" line.
mkdir -p "$tmp/log"
kept() { LOG="$tmp/log" guest "$tmp/real" kept signed-job b3:tree >"$tmp/out" 2>&1; }
echo "zcube-agent: container signed-job started" >"$tmp/log/agent.log"
EXPORT="$here/testdata/trust-export.txt" kept
check "kept passes when the node's store holds the lines" $?
EXPORT="$tmp/empty" kept
check "kept fails when the node's store holds none" $((! $? ))
echo "zcube-agent: container signed-job: its signatures were not kept in the node's Zigbox" \
    "store, and it starts: ZBX-E0909 a trust bundle was refused" >>"$tmp/log/agent.log"
EXPORT="$here/testdata/trust-export.txt" kept
check "kept fails on a 'not kept' line in the agent's log" $((! $? ))

[ "$failures" -eq 0 ] && echo "test-guest: ok"
exit "$failures"
