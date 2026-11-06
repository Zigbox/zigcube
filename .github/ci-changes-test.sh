#!/usr/bin/env bash
# Tests of .github/ci-changes.sh: a table of changed paths and the verdict each must get. The
# changes job runs it before it classifies, so a broken rule fails CI instead of skipping a job.
# Each row: EVENT|HEAD_REF|LABELS|paths (space separated)|expected `code store c0 c1 smoke c2 mtls` as T/F.
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
failed=0
n=0

check() {
  local event=$1 ref=$2 labels=$3 paths=$4 want=$5 got out
  # GITHUB_OUTPUT is set on a runner; unset, the script writes to stdout.
  out=$(printf '%s\n' ${paths} | env -u GITHUB_OUTPUT EVENT="$event" HEAD_REF="$ref" \
    LABELS="$labels" "$dir/ci-changes.sh" | tr '\n' ' ')
  got=$(echo "$out" | sed -E 's/code=true/T/; s/code=false/F/; s/store=true/T/; s/store=false/F/;
    s/demo_c0=true/T/; s/demo_c0=false/F/; s/demo_c1=true/T/; s/demo_c1=false/F/;
    s/zigbox_smoke=true/T/; s/zigbox_smoke=false/F/; s/demo_c2=true/T/; s/demo_c2=false/F/;
    s/mtls_interop=true/T/; s/mtls_interop=false/F/; s/ //g')
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL: $event ${ref:+[$ref] }${labels:+[$labels] }${paths:-<no paths>}: want $want, got $got"
    failed=$((failed + 1))
  fi
}

# Verdict order: code store demo_c0 demo_c1 zigbox_smoke demo_c2 mtls_interop.
PR=pull_request
# Documentation only: nothing runs.
check $PR x "" "README.md docs/core.md site/index.html" FFFFFFF
check $PR x "" "docs/demos/c1.md" FFFFFFF
# ...except src/ and web/ markdown, site/errors, and any code file.
check $PR x "" "src/README.md" TTTTTTT
check $PR x "" "web/README.md" TFFFFFF
check $PR x "" "site/errors/ZC-E0001.html" TFFFFFF
check $PR x "" "README.md ops/sim-fleet/run.sh" TFFFFFF
check $PR x "" "ops/sim-fleet/test-canary.sh ops/sim-fleet/test-crash-record.sh" TFFFFFF
# Docs only, but asked for in full.
check $PR x "full-ci" "README.md" TTTTTTT
check $PR claude/release-0.4 "" "README.md" TTTTTTT
# Narrow: tests, simulations, the web console, the tools, the gate's own runner.
check $PR x "" "src/scheduler_test.zig" TFFFFFF
check $PR x "" "src/sim_cluster.zig src/sim_swarm_main.zig" TFFFFFF
check $PR x "" "web/app.js web/mock/c1.js tools/wasm_check.mjs" TFFFFFF
check $PR x "" "src/tidy.zig src/testing/check.zig" TFFFFFF
check $PR x "" "src/console_wasm.zig src/web_embed.zig" TFFFFFF
# One demo, one smoke, the store suites' own files.
check $PR x "" "src/demo_c0_steps.zig" TFTFFFF
check $PR x "" "src/demo_c1_fleet.zig docs/demos/c1.md" TFFTFFF
check $PR x "" "src/zigbox_runtime.zig" TFFFTTF
check $PR x "" "ops/zigbox-smoke/guest.sh" TFFFTFF
check $PR x "" "src/store_faults.zig src/store_failover.zig" TTFFFFF
check $PR x "" "src/mtls_interop.zig" TFFFFFT
check $PR x "" "ops/mtls-interop/InteropServer.java" TFFFFFT
check $PR x "" "src/demo_c0.zig src/demo_c1.zig" TFTTFFF
# Everything: the build, CI itself, the shared demo driver, the server, the agent, the store
# backends, the core, and any path no rule names (also a new directory).
check $PR x "" "build.zig" TTTTTTT
check $PR x "" "build.zig.zon" TTTTTTT
check $PR x "" ".github/workflows/ci.yml" TTTTTTT
check $PR x "" ".github/ci-changes.sh" TTTTTTT
check $PR x "" "src/demo_host.zig" TTTTTTT
check $PR x "" "src/server.zig" TTTTTTT
check $PR x "" "src/agent_loop.zig" TTTTTTT
check $PR x "" "src/store_postgres.zig" TTTTTTT
check $PR x "" "src/store.zig" TTTTTTT
check $PR x "" "src/core.zig" TTTTTTT
check $PR x "" "src/c1_teeth.zig" TTTTTTT
# The sim job (which runs sim-fencing-teeth) runs on `code`: a change to the fencing arithmetic
# runs everything, one to the simulator alone runs the code jobs.
check $PR x "" "src/fencing.zig" TTTTTTT
check $PR x "" "src/sim_cluster.zig src/sim_c1_teeth_oldrule_main.zig" TFFFFFF
check $PR x "" "src/testing/fault_proxy.zig" TTTTTTT
check $PR x "" "src/brand_new_file.zig" TTTTTTT
check $PR x "" "newdir/file.txt" TTTTTTT
check $PR x "" "fixtures/images.zon" TTTTTTT
check $PR x "" "demo/up.sh" TTTTTTT
# demo-c2: its own files, its docs (off), an unknown path (on), the label and a release branch (on).
check $PR x "" "src/demo_c2_steps.zig ops/demo-c2/run.sh" TFFFFTF
check $PR x "" "docs/demos/c2.md" FFFFFFF
check $PR x "" "src/never_heard_of_it.zig" TTTTTTT
check $PR x "full-ci" "src/demo_c2.zig" TTTTTTT
check $PR claude/release-0.5 "" "src/demo_c2.zig" TTTTTTT
check $PR x "" "src/scheduler_test.zig src/demo_c2.zig" TFFFFTF
# A narrow path next to an unknown one runs everything; two narrow paths run the union.
check $PR x "" "src/scheduler_test.zig src/server.zig" TTTTTTT
check $PR x "" "src/zigbox_map.zig src/demo_c1_steps.zig" TFFTTTF
# Full: the label, a release branch, a push to main, an unlisted change.
check $PR x "full-ci" "src/scheduler_test.zig" TTTTTTT
check $PR x "bug full-ci" "src/scheduler_test.zig" TTTTTTT
check $PR x "full-cipher" "src/scheduler_test.zig" TFFFFFF
check $PR claude/release-0.4 "" "src/scheduler_test.zig" TTTTTTT
check $PR claude/ci-speed "" "src/scheduler_test.zig" TFFFFFF
check push main "" "src/scheduler_test.zig" TTTTTTT
check push main "" "web/app.js" TTTTTTT
check push main "" "README.md" FFFFFFF
check $PR x "" "" TTTTTTT
check push main "" "" TTTTTTT

if [ "$failed" -ne 0 ]; then
  echo "ci-changes-test: $failed of $n failed"
  exit 1
fi
echo "ci-changes-test: $n cases passed"
