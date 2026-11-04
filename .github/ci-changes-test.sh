#!/usr/bin/env bash
# Tests of .github/ci-changes.sh: a table of changed paths and the verdict each must get. The
# changes job runs it before it classifies, so a broken rule fails CI instead of skipping a job.
# Each row: EVENT|HEAD_REF|LABELS|paths (space separated)|expected `code store c0 c1 smoke` as T/F.
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
    s/zigbox_smoke=true/T/; s/zigbox_smoke=false/F/; s/ //g')
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL: $event ${ref:+[$ref] }${labels:+[$labels] }${paths:-<no paths>}: want $want, got $got"
    failed=$((failed + 1))
  fi
}

# Verdict order: code store demo_c0 demo_c1 zigbox_smoke.
PR=pull_request
# Documentation only: nothing runs.
check $PR x "" "README.md docs/core.md site/index.html" FFFFF
check $PR x "" "docs/demos/c1.md" FFFFF
# ...except src/ and web/ markdown, site/errors, and any code file.
check $PR x "" "src/README.md" TTTTT
check $PR x "" "web/README.md" TFFFF
check $PR x "" "site/errors/ZC-E0001.html" TFFFF
check $PR x "" "README.md ops/sim-fleet/run.sh" TFFFF
# Docs only, but asked for in full.
check $PR x "full-ci" "README.md" TTTTT
check $PR claude/release-0.4 "" "README.md" TTTTT
# Narrow: tests, simulations, the web console, the tools, the gate's own runner.
check $PR x "" "src/scheduler_test.zig" TFFFF
check $PR x "" "src/sim_cluster.zig src/sim_swarm_main.zig" TFFFF
check $PR x "" "web/app.js web/mock/c1.js tools/wasm_check.mjs" TFFFF
check $PR x "" "src/tidy.zig src/testing/check.zig" TFFFF
check $PR x "" "src/console_wasm.zig src/web_embed.zig" TFFFF
# One demo, one smoke, the store suites' own files.
check $PR x "" "src/demo_c0_steps.zig" TFTFF
check $PR x "" "src/demo_c1_fleet.zig docs/demos/c1.md" TFFTF
check $PR x "" "src/zigbox_runtime.zig" TFFFT
check $PR x "" "ops/zigbox-smoke/guest.sh" TFFFT
check $PR x "" "src/store_faults.zig src/store_failover.zig" TTFFF
check $PR x "" "src/demo_c0.zig src/demo_c1.zig" TFTTF
# Everything: the build, CI itself, the shared demo driver, the server, the agent, the store
# backends, the core, and any path no rule names (also a new directory).
check $PR x "" "build.zig" TTTTT
check $PR x "" "build.zig.zon" TTTTT
check $PR x "" ".github/workflows/ci.yml" TTTTT
check $PR x "" ".github/ci-changes.sh" TTTTT
check $PR x "" "src/demo_host.zig" TTTTT
check $PR x "" "src/server.zig" TTTTT
check $PR x "" "src/agent_loop.zig" TTTTT
check $PR x "" "src/store_postgres.zig" TTTTT
check $PR x "" "src/store.zig" TTTTT
check $PR x "" "src/core.zig" TTTTT
check $PR x "" "src/c1_teeth.zig" TTTTT
check $PR x "" "src/testing/fault_proxy.zig" TTTTT
check $PR x "" "src/brand_new_file.zig" TTTTT
check $PR x "" "newdir/file.txt" TTTTT
check $PR x "" "fixtures/images.zon" TTTTT
check $PR x "" "demo/up.sh" TTTTT
# A narrow path next to an unknown one runs everything; two narrow paths run the union.
check $PR x "" "src/scheduler_test.zig src/server.zig" TTTTT
check $PR x "" "src/zigbox_map.zig src/demo_c1_steps.zig" TFFTT
# Full: the label, a release branch, a push to main, an unlisted change.
check $PR x "full-ci" "src/scheduler_test.zig" TTTTT
check $PR x "bug full-ci" "src/scheduler_test.zig" TTTTT
check $PR x "full-cipher" "src/scheduler_test.zig" TFFFF
check $PR claude/release-0.4 "" "src/scheduler_test.zig" TTTTT
check $PR claude/ci-speed "" "src/scheduler_test.zig" TFFFF
check push main "" "src/scheduler_test.zig" TTTTT
check push main "" "web/app.js" TTTTT
check push main "" "README.md" FFFFF
check $PR x "" "" TTTTT
check push main "" "" TTTTT

if [ "$failed" -ne 0 ]; then
  echo "ci-changes-test: $failed of $n failed"
  exit 1
fi
echo "ci-changes-test: $n cases passed"
