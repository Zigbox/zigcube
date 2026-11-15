#!/usr/bin/env bash
# Tests of .github/ci-changes.sh: a table of changed paths and the verdict each must get. The
# changes job runs it before it classifies, so a broken rule fails CI instead of skipping a job.
# Each row: EVENT|HEAD_REF|LABELS|paths (space separated)|expected `code store c0 c1 b1 smoke c2 mtls b3 c3smoke c3` as T/F.
# `check` leaves the macos output out; `check_macos` rows judge it alone.
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
failed=0
n=0

check() {
  local event=$1 ref=$2 labels=$3 paths=$4 want=$5 got out
  # GITHUB_OUTPUT is set on a runner; unset, the script writes to stdout.
  out=$(printf '%s\n' ${paths} | env -u GITHUB_OUTPUT EVENT="$event" HEAD_REF="$ref" \
    LABELS="$labels" "$dir/ci-changes.sh" | grep -v '^macos=' | tr '\n' ' ')
  got=$(echo "$out" | sed -E 's/code=true/T/; s/code=false/F/; s/store=true/T/; s/store=false/F/;
    s/demo_c0=true/T/; s/demo_c0=false/F/; s/demo_c1=true/T/; s/demo_c1=false/F/;
    s/demo_b1=true/T/; s/demo_b1=false/F/;
    s/zigbox_smoke=true/T/; s/zigbox_smoke=false/F/; s/demo_c2=true/T/; s/demo_c2=false/F/;
    s/mtls_interop=true/T/; s/mtls_interop=false/F/; s/demo_b3=true/T/; s/demo_b3=false/F/;
    s/c3_smoke=true/T/; s/c3_smoke=false/F/; s/demo_c3=true/T/; s/demo_c3=false/F/; s/ //g')
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL: $event ${ref:+[$ref] }${labels:+[$labels] }${paths:-<no paths>}: want $want, got $got"
    failed=$((failed + 1))
  fi
}

# The macOS job: its own verdict, T or F.
check_macos() {
  local event=$1 ref=$2 labels=$3 paths=$4 want=$5 got
  got=$(printf '%s\n' ${paths} | env -u GITHUB_OUTPUT EVENT="$event" HEAD_REF="$ref" \
    LABELS="$labels" "$dir/ci-changes.sh" | sed -n 's/^macos=true$/T/p; s/^macos=false$/F/p')
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL: macos: $event ${ref:+[$ref] }${labels:+[$labels] }${paths:-<no paths>}: want $want, got $got"
    failed=$((failed + 1))
  fi
}

# Verdict order: code store demo_c0 demo_c1 demo_b1 zigbox_smoke demo_c2 mtls_interop demo_b3
# c3_smoke demo_c3.
PR=pull_request
# Documentation only: nothing runs.
check $PR x "" "README.md docs/core.md site/index.html" FFFFFFFFFFF
check $PR x "" "docs/demos/c1.md" FFFFFFFFFFF
# ...except src/ and web/ markdown, site/errors, and any code file.
check $PR x "" "src/README.md" TTTTTTTTTTT
check $PR x "" "web/README.md" TFFFFFFFFFF
check $PR x "" "site/errors/ZC-E0001.html" TFFFFFFFFFF
check $PR x "" "README.md ops/sim-fleet/run.sh" TFFFFFFFFFF
check $PR x "" "ops/sim-fleet/test-canary.sh ops/sim-fleet/test-crash-record.sh" TFFFFFFFFFF
# Docs only, but asked for in full.
check $PR x "full-ci" "README.md" TTTTTTTTTTT
check $PR claude/release-0.4 "" "README.md" TTTTTTTTTTT
# Narrow: tests, simulations, the web console, the tools, the gate's own runner.
check $PR x "" "src/scheduler_test.zig" TFFFFFFFFFF
check $PR x "" "src/sim_cluster.zig src/sim_swarm_main.zig" TFFFFFFFFFF
check $PR x "" "web/app.js web/mock/c1.js tools/wasm_check.mjs" TFFFFFFFFFF
check $PR x "" "src/tidy.zig src/testing/check.zig" TFFFFFFFFFF
check $PR x "" "src/console_wasm.zig src/web_embed.zig" TFFFFFFFFFF
check $PR x "" "src/mac_release.zig packaging/homebrew/zcube-resource.rb" TFFFFFFFFFF
# One demo, one smoke, the store suites' own files.
check $PR x "" "src/demo_c0_steps.zig" TFTFFFFFFFF
check $PR x "" "src/demo_c1_fleet.zig docs/demos/c1.md" TFFTTFFFTTF
check $PR x "" "src/demo_c1_state.zig" TFFTTFFFTFF
check $PR x "" "src/demo_c0_state.zig" TFTTTFFFTFF
check $PR x "" "src/demo_c1_partition.zig" TFFTFFFFFFF
check $PR x "" "src/zigbox_runtime.zig" TFFFFTTFTFT
check $PR x "" "ops/zigbox-smoke/guest.sh" TFFFFTFFFFF
check $PR x "" "src/store_faults.zig src/store_failover.zig" TTFFFFFFFFF
check $PR x "" "src/mtls_interop.zig" TFFFFFFTFFF
check $PR x "" "ops/mtls-interop/InteropServer.java" TFFFFFFTFFF
check $PR x "" "src/demo_c0.zig src/demo_c1.zig" TFTTFFFFFFF
# Everything: the build, CI itself, the shared demo driver, the server, the agent, the store
# backends, the core, and any path no rule names (also a new directory).
check $PR x "" "build.zig" TTTTTTTTTTT
check $PR x "" "build.zig.zon" TTTTTTTTTTT
check $PR x "" ".github/workflows/ci.yml" TTTTTTTTTTT
check $PR x "" ".github/ci-changes.sh" TTTTTTTTTTT
check $PR x "" "src/demo_host.zig" TTTTTTTTTTT
check $PR x "" "src/server.zig" TTTTTTTTTTT
check $PR x "" "src/agent_loop.zig" TTTTTTTTTTT
check $PR x "" "src/store_postgres.zig" TTTTTTTTTTT
check $PR x "" "src/store.zig" TTTTTTTTTTT
check $PR x "" "src/core.zig" TTTTTTTTTTT
check $PR x "" "src/c1_teeth.zig" TTTTTTTTTTT
# The sim job (which runs sim-fencing-teeth) runs on `code`: a change to the fencing arithmetic
# runs everything, one to the simulator alone runs the code jobs.
check $PR x "" "src/fencing.zig" TTTTTTTTTTT
check $PR x "" "src/sim_cluster.zig src/sim_c1_teeth_oldrule_main.zig" TFFFFFFFFFF
check $PR x "" "src/testing/fault_proxy.zig" TTTTTTTTTTT
check $PR x "" "src/brand_new_file.zig" TTTTTTTTTTT
check $PR x "" "newdir/file.txt" TTTTTTTTTTT
check $PR x "" "fixtures/images.zon" TTTTTTTTTTT
check $PR x "" "demo/up.sh" TTTTTTTTTTT
# demo-c2: its own files, its docs (off), an unknown path (on), the label and a release branch (on).
check $PR x "" "src/demo_c2_steps.zig ops/demo-c2/run.sh" TFFFFFTFTFF
check $PR x "" "docs/demos/c2.md" FFFFFFFFFFF
check $PR x "" "src/never_heard_of_it.zig" TTTTTTTTTTT
check $PR x "full-ci" "src/demo_c2.zig" TTTTTTTTTTT
check $PR claude/release-0.5 "" "src/demo_c2.zig" TTTTTTTTTTT
check $PR x "" "src/scheduler_test.zig src/demo_c2.zig" TFFFFFTFFFF
# demo-b3: its own files, the files it shares (demo-b1's state, demo-c2's rig), the relay.
check $PR x "" "src/demo_b3_script.zig ops/demo-b3/guest.sh" TFFFFFFFTFF
check $PR x "" "src/demo_c2_vms.zig" TFFFFFTFTFT
check $PR x "" "src/demo_b1_state.zig" TFFFTFFFTFF
check $PR x "" "src/relay.zig" TFFFFTTFTFT
check $PR x "" "docs/demos/b3.md" FFFFFFFFFFF
# A narrow path next to an unknown one runs everything; two narrow paths run the union.
check $PR x "" "src/scheduler_test.zig src/server.zig" TTTTTTTTTTT
check $PR x "" "src/zigbox_map.zig src/demo_c1_steps.zig" TFFTFTTFTFT
# Full: the label, a release branch, a push to main, an unlisted change.
check $PR x "full-ci" "src/scheduler_test.zig" TTTTTTTTTTT
check $PR x "bug full-ci" "src/scheduler_test.zig" TTTTTTTTTTT
check $PR x "full-cipher" "src/scheduler_test.zig" TFFFFFFFFFF
check $PR claude/release-0.4 "" "src/scheduler_test.zig" TTTTTTTTTTT
check $PR claude/ci-speed "" "src/scheduler_test.zig" TFFFFFFFFFF
check push main "" "src/scheduler_test.zig" TTTTTTTTTTT
check push main "" "web/app.js" TTTTTTTTTTT
check push main "" "README.md" FFFFFFFFFFF
check $PR x "" "" TTTTTTTTTTT
check push main "" "" TTTTTTTTTTT
# demo-b1's own files run demo-b1 only; docs/demos/b1.md is documentation.
check $PR x "" "src/demo_b1_nodes.zig docs/demos/b1.md" TFFFTFFFFFF
check $PR x "" "src/demo_b1.zig src/demo_c1.zig" TFFTTFFFFFF
# c3-smoke's steps and witness run c3-smoke and demo-c3; docs/demos/c3.md is documentation.
check $PR x "" "src/c3_smoke_steps.zig src/c3_witness.zig docs/demos/c3.md" TFFFFFFFFTT
# demo-c3: its own files; the smoke's driver is c3-smoke's alone; the rig and the adapter reach it.
check $PR x "" "src/demo_c3.zig ops/demo-c3/guest.sh" TFFFFFFFFFT
check $PR x "" "src/c3_smoke.zig" TFFFFFFFFTF
check $PR x "" "src/c3_smoke_steps.zig" TFFFFFFFFTT
check $PR x "" "src/demo_c2_steps.zig" TFFFFFTFTFF
check $PR x "" "src/c3_smoke.zig src/demo_c1_state.zig" TFFTTFFFTTF
check $PR x "" "docs/demos/c3.md" FFFFFFFFFFF

# The macOS job: zcube's own files, the build and CI run it; a server file, an unknown path and
# documentation do not; a full run does.
PR=pull_request
check_macos $PR x "" "src/cli_local.zig" T
check_macos $PR x "" "src/zcube.zig src/server.zig" T
check_macos $PR x "" "src/mac_release.zig" T
check_macos $PR x "" "packaging/homebrew/zcube-resource.rb" T
check_macos $PR x "" "build.zig" T
check_macos $PR x "" ".github/actions/setup-zig-macos/action.yml" T
check_macos $PR x "" ".github/workflows/ci.yml" T
check_macos $PR x "" "src/server.zig" F
check_macos $PR x "" "src/brand_new_file.zig" F
check_macos $PR x "" "src/diag/codes.zig" F
check_macos $PR x "" "docs/macos.md" F
check_macos $PR x "" "README.md src/cli_local.zig" T
check_macos $PR x "full-ci" "src/server.zig" T
check_macos $PR claude/release-0.6 "" "src/server.zig" T
check_macos push main "" "src/server.zig" T
check_macos push main "" "README.md" F
check_macos $PR x "" "" T

if [ "$failed" -ne 0 ]; then
  echo "ci-changes-test: $failed of $n failed"
  exit 1
fi
echo "ci-changes-test: $n cases passed"
